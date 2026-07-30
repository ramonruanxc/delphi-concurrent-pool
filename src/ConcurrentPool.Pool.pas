{
  ConcurrentPool — a fixed-size worker pool.

  Visibly a composition of the other three units, and that is deliberate: the
  pool is where they are shown working together, not where new machinery
  appears. If this file grows much past 250 lines, something in it belongs in
  Queue or Worker.

  Two rules hold the concurrency together.

  LOCKS ARE LEAF-LEVEL. No component calls user code, another component, or an
  allocation-heavy operation while holding a lock. Item.Run is invoked with
  nothing held, which is why submitting more work from inside a running task
  works, and why the pool tracks Pending in its own counter instead of asking
  the queue while holding FLock. There is consequently no lock nesting anywhere
  in the library and so no lock order to invert.

  THE ACCOUNTING IS AN INVARIANT, NOT A REPORT.

      Submitted = Completed + Faulted + Dropped + (still queued or in flight)

  and once the pool is idle or shut down the trailing term is zero. Asserting
  that is a race-free proof that work is never lost and never run twice — much
  stronger than checking that a counter reached N.
}
unit ConcurrentPool.Pool;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs{$ENDIF},
  ConcurrentPool.Types,
  ConcurrentPool.Atomic,
  ConcurrentPool.Queue,
  ConcurrentPool.Worker;

type
  TWorkerPool = class
  strict private
    FQueue: TBoundedQueue<IRunnable>;
    FWorkers: array of TWorker;
    { A leaf lock. Never held across Run, Push, Pop or a join. }
    FLock: TCriticalSection;
    { Manual-reset, and STATE rather than a transition, exactly like the queue's
      events — which is why there is no Sleep anywhere in src/. }
    FIdle: TEvent;
    FSubmitted: TAtomicCounter;
    FCompleted: TAtomicCounter;
    FFaulted: TAtomicCounter;
    FDropped: TAtomicCounter;
    FPending: TAtomicCounter;
    FInFlight: TAtomicCounter;
    FShutdown: TAtomicCounter;
    procedure RefreshIdleLocked;
    procedure CheckNotSelf;
    procedure CancelWorkers;
    function JoinWorkers(ATimeoutMs: Cardinal): Boolean;
  private
    { Called by the drain runnable, which lives in this unit's implementation. }
    procedure BeginItem;
    procedure EndItem(AFaulted: Boolean);
    function TakeWork(out AItem: IRunnable): TQueueWait;
  public
    constructor Create(AWorkerCount, AQueueCapacity: Integer);
    destructor Destroy; override;

    { The interface is taken BY VALUE, not as const, and that is a correctness
      decision rather than a style one.

      A const interface parameter does not take a reference. So when a caller
      writes the natural thing —

          Pool.Submit(TMyJob.Create);

      — and the queue REFUSES the item (qwClosed after a shutdown, or qwTimeout
      on a full queue), nothing ever holds a reference to that object: it is
      never stored, its refcount stays at zero, and it is never freed. A leak,
      once per refused submission, in the path a caller is least likely to test.
      Taking it by value gives it a reference for the duration of the call, so it
      is released on the way out. Found by this repo's own leak gate.

      Non-blocking by default. Pass a timeout to get back-pressure instead of an
      immediate qwTimeout when the queue is full. Returns qwClosed after a
      shutdown — never raises, never blocks.

      A task may Submit. If it submits into a FULL queue while every worker is
      also blocked in Submit, that deadlocks — inherent to any bounded-queue
      pool, and the reason the timeout form exists: it lets a caller fail
      instead of hang. }
    function Submit(ARunnable: IRunnable;
      ATimeoutMs: Cardinal = 0): TQueueWait;

    { True when everything submitted has finished. }
    function WaitIdle(ATimeoutMs: Cardinal): Boolean;

    { Close the queue and let the workers drain what is already in it, then
      join. Returns False if a worker did not stop within the timeout. }
    function Shutdown(ATimeoutMs: Cardinal): Boolean;

    { Close the queue, RELEASE whatever is still in it (counted as Dropped),
      cancel every worker, then join. }
    function ShutdownNow(ATimeoutMs: Cardinal): Boolean;

    function Submitted: Integer;
    function Completed: Integer;
    function Faulted: Integer;
    function Dropped: Integer;
    { Queued but not yet picked up. Advisory. }
    function Pending: Integer;
    function InFlight: Integer;
    function WorkerCount: Integer;
    function IsShutdown: Boolean;
  end;

implementation

const
  { The pool's cancellation granularity: a worker parked in Pop wakes at least
    this often to re-check its token, so Cancel works whether or not Close
    happened first. Deliberate, documented, and cheap. }
  POOL_POLL_MS = 50;

type
  { One of these per worker. Not exposed: a caller gets a pool, not a loop. }
  TDrainRunnable = class(TInterfacedObject, IRunnable)
  strict private
    FPool: TWorkerPool;
  public
    constructor Create(APool: TWorkerPool);
    procedure Run(const AToken: ICancellationToken);
  end;

constructor TDrainRunnable.Create(APool: TWorkerPool);
begin
  inherited Create;
  FPool := APool;
end;

procedure TDrainRunnable.Run(const AToken: ICancellationToken);
var
  Item: IRunnable;
begin
  while not AToken.IsCancelled do
  begin
    case FPool.TakeWork(Item) of
      qwOK:
        begin
          FPool.BeginItem;
          try
            { No lock is held here. That is the one structural rule of the
              library, and it is what makes Submit-from-inside-Run legal. }
            Item.Run(AToken);
            FPool.EndItem(False);
          except
            { A faulting item must not take the worker down with it — the pool
              would silently shrink. }
            FPool.EndItem(True);
          end;
          Item := nil;
        end;
      qwTimeout:
        { Nothing to do: loop and re-check the token. }
        ;
      qwClosed:
        Break;
    end;
  end;
end;

{ TWorkerPool }

constructor TWorkerPool.Create(AWorkerCount, AQueueCapacity: Integer);
var
  I: Integer;
begin
  inherited Create;

  { Counters first, before anything that can raise: a constructor that raises
    still has its destructor called on the half-built object, and Destroy reads
    them. Init cannot fail. }
  FSubmitted.Init;
  FCompleted.Init;
  FFaulted.Init;
  FDropped.Init;
  FPending.Init;
  FInFlight.Init;
  FShutdown.Init;

  if AWorkerCount < 1 then
    raise EPoolArgument.CreateFmt(
      'Worker count must be at least 1, got %d.', [AWorkerCount]);
  if AQueueCapacity < 1 then
    raise EPoolArgument.CreateFmt(
      'Queue capacity must be at least 1, got %d.', [AQueueCapacity]);

  FQueue := TBoundedQueue<IRunnable>.Create(AQueueCapacity);
  FLock := TCriticalSection.Create;
  { Starts signalled: an empty pool is idle. }
  FIdle := TEvent.Create(nil, True, True, '');

  { If starting a worker raises, the destructor still runs on a partially
    constructed object — so it has to tolerate every field being nil, and the
    workers already running have to be stopped before the exception leaves. }
  SetLength(FWorkers, AWorkerCount);
  try
    for I := 0 to AWorkerCount - 1 do
    begin
      FWorkers[I] := TWorker.Create(TDrainRunnable.Create(Self));
      FWorkers[I].Start;
    end;
  except
    ShutdownNow(WAIT_INFINITE);
    raise;
  end;
end;

destructor TWorkerPool.Destroy;
var
  I: Integer;
begin
  { A destructor must terminate, so it abandons queued work rather than waiting
    for it. Call Shutdown explicitly first when the queue should be drained. }
  if FQueue <> nil then
    ShutdownNow(WAIT_INFINITE);

  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
      FWorkers[I].Free;
  SetLength(FWorkers, 0);

  FQueue.Free;
  FIdle.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TWorkerPool.CheckNotSelf;
var
  I: Integer;
  Current: TThreadID;
begin
  Current := TThread.CurrentThread.ThreadID;
  for I := 0 to High(FWorkers) do
    if (FWorkers[I] <> nil) and (FWorkers[I].State = wsRunning) then
      { TWorker raises on its own self-join; this catches the pool-level case,
        where a task asks the pool that owns it to shut down. Without it the
        worker would be waiting for itself through one more level of
        indirection. }
      if FWorkers[I].ThreadID = Current then
        raise EPoolSelfJoin.Create(
          'A pool cannot be shut down or waited on from inside one of its own ' +
          'tasks.');
end;

procedure TWorkerPool.RefreshIdleLocked;
begin
  if (FPending.Value = 0) and (FInFlight.Value = 0) then
    FIdle.SetEvent
  else
    FIdle.ResetEvent;
end;

function TWorkerPool.TakeWork(out AItem: IRunnable): TQueueWait;
begin
  Result := FQueue.Pop(AItem, POOL_POLL_MS);
  if Result = qwOK then
  begin
    FLock.Enter;
    try
      FPending.Decrement;
    finally
      FLock.Leave;
    end;
  end;
end;

procedure TWorkerPool.BeginItem;
begin
  FLock.Enter;
  try
    FInFlight.Increment;
    RefreshIdleLocked;
  finally
    FLock.Leave;
  end;
end;

procedure TWorkerPool.EndItem(AFaulted: Boolean);
begin
  FLock.Enter;
  try
    FInFlight.Decrement;
    if AFaulted then
      FFaulted.Increment
    else
      FCompleted.Increment;
    RefreshIdleLocked;
  finally
    FLock.Leave;
  end;
end;

function TWorkerPool.Submit(ARunnable: IRunnable;
  ATimeoutMs: Cardinal): TQueueWait;
begin
  if ARunnable = nil then
    raise EPoolArgument.Create('Submit requires a runnable.');

  { Counted BEFORE the push, and rolled back if the push fails. The only
    observable consequence of that ordering is over-waiting in WaitIdle; the
    reverse order would let WaitIdle see 0 = 0 and return before the item was
    ever queued. }
  FLock.Enter;
  try
    FSubmitted.Increment;
    FPending.Increment;
    RefreshIdleLocked;
  finally
    FLock.Leave;
  end;

  Result := FQueue.Push(ARunnable, ATimeoutMs);

  if Result <> qwOK then
  begin
    FLock.Enter;
    try
      FSubmitted.Decrement;
      FPending.Decrement;
      RefreshIdleLocked;
    finally
      FLock.Leave;
    end;
  end;
end;

function TWorkerPool.WaitIdle(ATimeoutMs: Cardinal): Boolean;
begin
  CheckNotSelf;
  Result := FIdle.WaitFor(ATimeoutMs) = wrSignaled;
end;

procedure TWorkerPool.CancelWorkers;
var
  I: Integer;
begin
  { Cooperative: it sets each token. A drain loop notices on its next pass, at
    worst one POOL_POLL_MS slice away. }
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
      FWorkers[I].Cancel;
end;

function TWorkerPool.JoinWorkers(ATimeoutMs: Cardinal): Boolean;
var
  I: Integer;
  Start: UInt64;
begin
  Result := True;
  Start := Ticks;
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
      { One deadline across all the joins, not one timeout each. }
      if not FWorkers[I].WaitFor(Remaining(Start, ATimeoutMs)) then
        Result := False;
end;

function TWorkerPool.Shutdown(ATimeoutMs: Cardinal): Boolean;
begin
  CheckNotSelf;
  FShutdown.Exchange(1);
  { Close, but do not drain: the workers finish what is already queued, then see
    qwClosed and leave. }
  FQueue.Close;
  Result := JoinWorkers(ATimeoutMs);
end;

function TWorkerPool.ShutdownNow(ATimeoutMs: Cardinal): Boolean;
var
  Abandoned: Integer;
begin
  CheckNotSelf;
  FShutdown.Exchange(1);

  { Abandoned items are released here and counted, so the accounting invariant
    still balances after a hard shutdown. }
  Abandoned := FQueue.DrainAndClose;
  if Abandoned > 0 then
  begin
    FLock.Enter;
    try
      FDropped.Add(Abandoned);
      FPending.Add(-Abandoned);
      RefreshIdleLocked;
    finally
      FLock.Leave;
    end;
  end;

  CancelWorkers;
  Result := JoinWorkers(ATimeoutMs);
end;

function TWorkerPool.Submitted: Integer;
begin
  Result := FSubmitted.Value;
end;

function TWorkerPool.Completed: Integer;
begin
  Result := FCompleted.Value;
end;

function TWorkerPool.Faulted: Integer;
begin
  Result := FFaulted.Value;
end;

function TWorkerPool.Dropped: Integer;
begin
  Result := FDropped.Value;
end;

function TWorkerPool.Pending: Integer;
begin
  Result := FPending.Value;
end;

function TWorkerPool.InFlight: Integer;
begin
  Result := FInFlight.Value;
end;

function TWorkerPool.WorkerCount: Integer;
begin
  Result := Length(FWorkers);
end;

function TWorkerPool.IsShutdown: Boolean;
begin
  Result := FShutdown.Value <> 0;
end;

end.
