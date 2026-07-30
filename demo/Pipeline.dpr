{
  ConcurrentPool demo 2 — cancellation and faults.

  The async sink demo shows the happy path. This one shows the two things that
  actually decide whether a pool is usable in production:

    - a task that FAILS does not take its worker down, and the failure is
      reported rather than lost;
    - a long-running task can be CANCELLED, including one that is parked in a
      wait rather than spinning in a loop.

  Both are visible in the output.

    Free Pascal   fpc -Mdelphi -Fu../src Pipeline.dpr
    Delphi        open in the IDE and build
}
program Pipeline;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ELSE}
  {$APPTYPE CONSOLE}
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

procedure ShowFaultIsolation;
const
  JOBS = 70;
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

    Pool.Shutdown(10000);
  finally
    Pool.Free;
    Tally.Free;
  end;
end;

{ ------------------------------------------------------------ cancellation }

procedure ShowCancellation;
var
  Pool: TWorkerPool;
  Polling: TPollingJob;
  Parked: TParkedJob;
  PollingRef, ParkedRef: IRunnable;
  T0: UInt64;
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
    Pool.ShutdownNow(10000);

    Report('shutdown took (ms)', IntToStr(Elapsed(T0)));
    Report('polling job units before it stopped', IntToStr(Polling.UnitsDone));
    Report('parked job was released by cancel',
      BoolToStr(Parked.ReleasedByCancel, True));
    Report('parked job waited (ms)', IntToStr(Parked.WaitedMs) +
      ' — not its 30000 ms timeout');
  finally
    Pool.Free;
  end;
end;

begin
  WriteLn('ConcurrentPool — faults and cancellation demo');

  ShowFaultIsolation;
  ShowCancellation;

  WriteLn;
  WriteLn('The parked job is the one worth noticing. A cancellation token that');
  WriteLn('could only be polled would never have released it, and the shutdown');
  WriteLn('would have waited out its full timeout — or blocked forever, had the');
  WriteLn('timeout been infinite.');
end.
