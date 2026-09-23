{
  ConcurrentPool demo 2 — cancellation and faults.

  The async sink demo shows the happy path. This one shows the two things that
  actually decide whether a pool is usable in production:

    - a task that FAILS does not take its worker down, and the failure is
      reported rather than lost;
    - a long-running task can be CANCELLED, including one that is parked in a
      wait rather than spinning in a loop.

  Both are visible in the output.

    Free Pascal   fpc demo/Pipeline.dpr     (from the repository root)
    Delphi        open this file in the IDE (XE7 or later) and press F9

  Nothing to configure on either compiler: every unit below carries its path.
  The last line printed is "RESULT: PASS ..." or "RESULT: FAIL ..." (exit 1).
}
program Pipeline;

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
  {$IFDEF FPC}SysUtils, Classes{$ELSE}System.SysUtils, System.Classes{$ENDIF},
  ConcurrentPool.Types in '../src/ConcurrentPool.Types.pas',
  ConcurrentPool.Atomic in '../src/ConcurrentPool.Atomic.pas',
  ConcurrentPool.Queue in '../src/ConcurrentPool.Queue.pas',
  ConcurrentPool.Worker in '../src/ConcurrentPool.Worker.pas',
  ConcurrentPool.Pool in '../src/ConcurrentPool.Pool.pas';

type
  TTally = class
  public
    Ok: TAtomicCounter;
    constructor Create;
  end;

  { Succeeds on most inputs and throws on every seventh, so a run mixes both. }
  TMaybeFailingJob = class(TInterfacedObject, IRunnable)
  strict private
    FTally: TTally;
    FIndex: Integer;
  public
    constructor Create(ATally: TTally; AIndex: Integer);
    procedure Run(const AToken: ICancellationToken);
  end;

  { Polls its token between units of work: the common shape. }
  TPollingJob = class(TInterfacedObject, IRunnable)
  strict private
    FUnitsDone: TAtomicCounter;
  public
    constructor Create;
    procedure Run(const AToken: ICancellationToken);
    function UnitsDone: Integer;
  end;

  { Waits on something instead of polling. A token that could only be POLLED
    could never release this task, so Cancel followed by a join would deadlock —
    which is why ICancellationToken also has WaitCancelled. }
  TParkedJob = class(TInterfacedObject, IRunnable)
  strict private
    FReleasedByCancel: Boolean;
    FWaitedMs: Cardinal;
  public
    procedure Run(const AToken: ICancellationToken);
    property ReleasedByCancel: Boolean read FReleasedByCancel;
    property WaitedMs: Cardinal read FWaitedMs;
  end;

constructor TTally.Create;
begin
  inherited Create;
  Ok.Init;
end;

constructor TMaybeFailingJob.Create(ATally: TTally; AIndex: Integer);
begin
  inherited Create;
  FTally := ATally;
  FIndex := AIndex;
end;

procedure TMaybeFailingJob.Run(const AToken: ICancellationToken);
begin
  if FIndex mod 7 = 0 then
    raise Exception.CreateFmt('job %d could not be processed', [FIndex]);
  FTally.Ok.Increment;
end;

constructor TPollingJob.Create;
begin
  inherited Create;
  FUnitsDone.Init;
end;

procedure TPollingJob.Run(const AToken: ICancellationToken);
begin
  { Would run for a very long time. Cancellation is what stops it, and it is
    cooperative: a task that never looked at its token could not be stopped at
    all, which is stated plainly rather than worked around with TerminateThread. }
  while not AToken.IsCancelled do
  begin
    FUnitsDone.Increment;
    Sleep(5);
  end;
end;

function TPollingJob.UnitsDone: Integer;
begin
  Result := FUnitsDone.Value;
end;

procedure TParkedJob.Run(const AToken: ICancellationToken);
var
  T0: UInt64;
begin
  T0 := Ticks;
  { Asks to be woken either by cancellation or by its own generous timeout. }
  FReleasedByCancel := AToken.WaitCancelled(30000);
  FWaitedMs := Elapsed(T0);
end;

procedure Report(const AName, AValue: string);
begin
  { Explicit %-40s: Write's `X: -40` field width is accepted and then silently
    ignored, which left the columns ragged. }
  WriteLn(Format('  %-40s %s', [AName, AValue]));
end;

{ ----------------------------------------------------------------- faults }

function ShowFaultIsolation: Boolean;
const
  JOBS = 70;
  { Every seventh of 1..70 throws. }
  FAULTS = JOBS div 7;
var
  Pool: TWorkerPool;
  Tally: TTally;
  I: Integer;
begin
  WriteLn;
  WriteLn('A failing task must not take its worker with it.');
  WriteLn('  Every seventh job throws. If a fault killed its worker the pool');
  WriteLn('  would silently shrink and the later jobs would never run.');
  WriteLn;

  Tally := TTally.Create;
  Pool := TWorkerPool.Create(4, 32);
  try
    for I := 1 to JOBS do
      Pool.Submit(TMaybeFailingJob.Create(Tally, I), 5000);

    Pool.WaitIdle(30000);

    Report('jobs submitted', IntToStr(Pool.Submitted));
    Report('completed', IntToStr(Pool.Completed));
    Report('faulted', IntToStr(Pool.Faulted));
    Report('successful jobs really ran', IntToStr(Tally.Ok.Value));
    Report('workers still alive', IntToStr(Pool.WorkerCount));
    Report('Submitted = Completed + Faulted + Dropped',
      Format('%d = %d + %d + %d', [Pool.Submitted, Pool.Completed,
        Pool.Faulted, Pool.Dropped]));

    Result := (Pool.Submitted = JOBS) and (Pool.Faulted = FAULTS) and
      (Pool.Completed = JOBS - FAULTS) and (Tally.Ok.Value = JOBS - FAULTS) and
      (Pool.Dropped = 0);

    if not Pool.Shutdown(10000) then
      Result := False;
  finally
    Pool.Free;
    Tally.Free;
  end;
end;

{ ------------------------------------------------------------ cancellation }

function ShowCancellation: Boolean;
var
  Pool: TWorkerPool;
  Polling: TPollingJob;
  Parked: TParkedJob;
  PollingRef, ParkedRef: IRunnable;
  T0: UInt64;
  Stopped: Boolean;
begin
  WriteLn;
  WriteLn('Cancellation reaches a task that is WAITING, not just one that polls.');
  WriteLn;

  Polling := TPollingJob.Create;
  PollingRef := Polling;
  Parked := TParkedJob.Create;
  ParkedRef := Parked;

  Pool := TWorkerPool.Create(2, 8);
  try
    Pool.Submit(PollingRef, 5000);
    Pool.Submit(ParkedRef, 5000);

    { Let them settle into their respective shapes: one looping, one parked. }
    Sleep(300);

    T0 := Ticks;
    { ShutdownNow cancels every worker, so both tasks are asked to stop. }
    Stopped := Pool.ShutdownNow(10000);

    Report('shutdown took (ms)', IntToStr(Elapsed(T0)));
    Report('polling job units before it stopped', IntToStr(Polling.UnitsDone));
    Report('parked job was released by cancel',
      BoolToStr(Parked.ReleasedByCancel, True));
    Report('parked job waited (ms)', IntToStr(Parked.WaitedMs) +
      ' - not its 30000 ms timeout');

    Result := Stopped and (Polling.UnitsDone > 0) and Parked.ReleasedByCancel;
  finally
    Pool.Free;
  end;
end;

var
  FaultsOk, CancelOk: Boolean;
begin
  WriteLn('ConcurrentPool - faults and cancellation demo');

  FaultsOk := ShowFaultIsolation;
  CancelOk := ShowCancellation;

  WriteLn;
  WriteLn('The parked job is the one worth noticing. A cancellation token that');
  WriteLn('could only be polled would never have released it, and the shutdown');
  WriteLn('would have waited out its full timeout - or blocked forever, had the');
  WriteLn('timeout been infinite.');
  WriteLn;

  if FaultsOk and CancelOk then
    WriteLn('RESULT: PASS - Pipeline: faults isolated and counted, ' +
      'the parked task released by cancellation.')
  else
  begin
    WriteLn('RESULT: FAIL - Pipeline: see the numbers above.');
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
