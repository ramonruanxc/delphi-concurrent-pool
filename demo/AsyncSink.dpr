{
  ConcurrentPool demo 1 — the async sink.

  This demo exists to close a loop. The sibling library, delphi-concurrent-log,
  ends its README with:

    "The cost is that sinks run serially while the lock is held, so a slow sink
     slows every logging thread. If you need to log across a slow sink without
     blocking callers, put a queue in front of it — a sink that hands entries to
     a background writer thread. That is a natural extension and intentionally
     left out of the core."

  This is that extension, built from the primitives in this repo and with no
  dependency on the logger itself: a deliberately slow "sink", a bounded queue
  in front of it, and one worker draining it. The producers hand work over and
  keep going.

  It also shows the back-pressure decision that any such design has to make.
  When the queue fills, a producer either waits or drops — and this demo does
  both, so the difference is visible in the numbers at the end.

    Free Pascal   fpc demo/AsyncSink.dpr     (from the repository root)
    Delphi        open this file in the IDE (XE7 or later) and press F9

  Nothing to configure on either compiler: every unit below carries its path.
  The last line printed is "RESULT: PASS ..." or "RESULT: FAIL ..." (exit 1).
}
program AsyncSink;

{$IFDEF FPC}
  {$MODE DELPHI}
  { FPC resolves in-paths from the working directory; UNITPATH is relative
    to this file, so the command above also works from the repository root. }
  {$UNITPATH ../src}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
  { DebugHook, used for the pause at the end, is marked `platform`. }
  {$WARN SYMBOL_PLATFORM OFF}
{$ENDIF}

uses
  {$IF DEFINED(FPC) AND DEFINED(UNIX)}
  cthreads,
  {$IFEND}
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs{$ENDIF},
  ConcurrentPool.Types in '../src/ConcurrentPool.Types.pas',
  ConcurrentPool.Atomic in '../src/ConcurrentPool.Atomic.pas',
  ConcurrentPool.Queue in '../src/ConcurrentPool.Queue.pas',
  ConcurrentPool.Worker in '../src/ConcurrentPool.Worker.pas',
  ConcurrentPool.Pool in '../src/ConcurrentPool.Pool.pas';

type
  { Stands in for a sink that is expensive to write to — a file on a slow disk,
    a socket, a database. Two milliseconds per line is enough to make the point
    without making the demo tedious. }
  TSlowSink = class
  strict private
    FLock: TCriticalSection;
    FWritten: TAtomicCounter;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Write(const ALine: string);
    function Written: Integer;
  end;

  { One queued log line. A class rather than a record because the queue holds
    interfaces, which is what gives the pending work a lifetime the queue owns —
    abandon it on shutdown and it is released, not leaked. }
  TLogLine = class(TInterfacedObject, IRunnable)
  strict private
    FSink: TSlowSink;
    FText: string;
  public
    constructor Create(ASink: TSlowSink; const AText: string);
    procedure Run(const AToken: ICancellationToken);
  end;

constructor TSlowSink.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWritten.Init;
end;

destructor TSlowSink.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TSlowSink.Write(const ALine: string);
begin
  { Serialised, exactly like the sibling logger's sinks: the point of the queue
    is that this cost is paid by the worker, not by whoever produced the line. }
  FLock.Enter;
  try
    Sleep(2);
    FWritten.Increment;
  finally
    FLock.Leave;
  end;
end;

function TSlowSink.Written: Integer;
begin
  Result := FWritten.Value;
end;

constructor TLogLine.Create(ASink: TSlowSink; const AText: string);
begin
  inherited Create;
  FSink := ASink;
  FText := AText;
end;

procedure TLogLine.Run(const AToken: ICancellationToken);
begin
  FSink.Write(FText);
end;

procedure Report(const AName: string; const AValue: string);
begin
  { Format with an explicit %-40s rather than Write's `X: -40` field width —
    a negative width is accepted by the compiler and then silently ignored, so
    the columns came out ragged. }
  WriteLn(Format('  %-40s %s', [AName, AValue]));
end;

{ ------------------------------------------------------------- back-pressure }

{ True when the pool's accounting balances once it has shut down. }
function Balanced(APool: TWorkerPool): Boolean;
begin
  Result := APool.Submitted =
    APool.Completed + APool.Faulted + APool.Dropped;
end;

function RunWithBackPressure: Boolean;
const
  LINES = 400;
var
  Sink: TSlowSink;
  Pool: TWorkerPool;
  I: Integer;
  T0: UInt64;
  Accepted: Integer;
begin
  WriteLn;
  WriteLn('Back-pressure: producers WAIT when the queue is full.');
  WriteLn('  Submit is given a timeout, so a full queue slows the producer down');
  WriteLn('  instead of losing a line. Nothing is dropped.');
  WriteLn;

  Sink := TSlowSink.Create;
  { A small queue on purpose, so it fills and the back-pressure is real. }
  Pool := TWorkerPool.Create(1, 16);
  try
    T0 := Ticks;
    Accepted := 0;
    for I := 1 to LINES do
      if Pool.Submit(TLogLine.Create(Sink, Format('line %d', [I])), 5000) = qwOK then
        Inc(Accepted);

    Pool.WaitIdle(30000);
    Pool.Shutdown(10000);

    Report('lines offered', IntToStr(LINES));
    Report('accepted', IntToStr(Accepted));
    Report('written to the sink', IntToStr(Sink.Written));
    Report('dropped', IntToStr(Pool.Dropped));
    Report('elapsed (ms)', IntToStr(Elapsed(T0)));
    Report('Submitted = Completed + Faulted + Dropped',
      Format('%d = %d + %d + %d', [Pool.Submitted, Pool.Completed,
        Pool.Faulted, Pool.Dropped]));

    { Waiting producers lose nothing: every line offered reached the sink. }
    Result := (Accepted = LINES) and (Sink.Written = LINES) and
      (Pool.Dropped = 0) and Balanced(Pool);
  finally
    Pool.Free;
    Sink.Free;
  end;
end;

{ -------------------------------------------------------------------- dropping }

function RunWithDropping: Boolean;
const
  LINES = 400;
var
  Sink: TSlowSink;
  Pool: TWorkerPool;
  I: Integer;
  T0: UInt64;
  Accepted, Refused: Integer;
begin
  WriteLn;
  WriteLn('Dropping: producers NEVER wait.');
  WriteLn('  Submit with no timeout returns qwTimeout the moment the queue is');
  WriteLn('  full, so the producer keeps its speed and loses lines instead.');
  WriteLn('  Which of the two you want is an application decision, and this is');
  WriteLn('  why Submit reports it rather than deciding for you.');
  WriteLn;

  Sink := TSlowSink.Create;
  Pool := TWorkerPool.Create(1, 16);
  try
    T0 := Ticks;
    Accepted := 0;
    Refused := 0;
    for I := 1 to LINES do
      if Pool.Submit(TLogLine.Create(Sink, Format('line %d', [I]))) = qwOK then
        Inc(Accepted)
      else
        Inc(Refused);

    Pool.WaitIdle(30000);
    Pool.Shutdown(10000);

    Report('lines offered', IntToStr(LINES));
    Report('accepted', IntToStr(Accepted));
    Report('refused at the door', IntToStr(Refused));
    Report('written to the sink', IntToStr(Sink.Written));
    Report('elapsed (ms)', IntToStr(Elapsed(T0)));
    Report('Submitted = Completed + Faulted + Dropped',
      Format('%d = %d + %d + %d', [Pool.Submitted, Pool.Completed,
        Pool.Faulted, Pool.Dropped]));

    { How many are refused depends on timing; that every line is either
      written or refused, and none twice, does not. }
    Result := (Accepted + Refused = LINES) and
      (Sink.Written = Accepted) and Balanced(Pool);
  finally
    Pool.Free;
    Sink.Free;
  end;
end;

var
  BackPressureOk, DroppingOk: Boolean;
begin
  WriteLn('ConcurrentPool - async sink demo');
  WriteLn('A slow sink behind a bounded queue, drained by one worker.');

  BackPressureOk := RunWithBackPressure;
  DroppingOk := RunWithDropping;

  WriteLn;
  WriteLn('Note that in both runs the accounting balances exactly. That');
  WriteLn('invariant - Submitted = Completed + Faulted + Dropped - is asserted');
  WriteLn('at the end of every pool test, and is what proves no work is ever');
  WriteLn('lost or run twice.');
  WriteLn;

  if BackPressureOk and DroppingOk then
    WriteLn('RESULT: PASS - AsyncSink: nothing lost with back-pressure, ' +
      'every line accounted for when dropping.')
  else
  begin
    WriteLn('RESULT: FAIL - AsyncSink: the numbers above do not balance.');
    ExitCode := 1;
  end;

  { Keeps the console open when started from the Delphi IDE with F9. Never
    pauses on Free Pascal, in CI, or when run from a command line. }
  {$IFNDEF FPC}
  if DebugHook <> 0 then
  begin
    Write('Press Enter to exit...');
    ReadLn;
  end;
  {$ENDIF}
end.
