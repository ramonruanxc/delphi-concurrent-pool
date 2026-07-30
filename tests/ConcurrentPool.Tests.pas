{
  ConcurrentPool — the suite.

  Two rules the whole file obeys.

  EVERY WAIT IS BOUNDED. WAIT_INFINITE never appears here. A hazard in this
  library fails by blocking, so an unbounded wait in a test converts a bug into
  a hang, and a hang names nothing. Bounded waits turn the same bug into an
  assertion with a message.

  THE DETERMINISTIC TESTS COME FIRST. Anything that depends on timing or on
  having more than one core is grouped at the end and labelled, so a reader can
  see at a glance which evidence is airtight and which is statistical.
}
unit ConcurrentPool.Tests;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  ConcurrentPool.Testing;

procedure RunTests(ARunner: TTestRunner; ARunGuardTests: Boolean);

implementation

uses
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs{$ENDIF},
  ConcurrentPool.Types,
  ConcurrentPool.Atomic,
  ConcurrentPool.Queue,
  ConcurrentPool.Worker,
  ConcurrentPool.Pool;

const
  { Generous enough that a loaded 2-core CI runner never trips it, small enough
    that a genuine deadlock fails the build in seconds rather than minutes. }
  BLOCK_MS = 5000;
  SETTLE_MS = 200;

type
  { ---------------------------------------------------------------- fixtures }

  THolder = class
  public
    Counter: TAtomicCounter;
    constructor Create;
  end;

  { Hammers one shared counter. The lost-update proof. }
  TBumper = class(TThread)
  strict private
    FHolder: THolder;
    FGate: TEvent;
    FRounds: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AHolder: THolder; AGate: TEvent; ARounds: Integer);
  end;

  { Pushes a fixed range into a queue, recording how each push ended. }
  TProducer = class(TThread)
  strict private
    FQueue: TBoundedQueue<Integer>;
    FFirst, FLast: Integer;
    FLastResult: TQueueWait;
    FPushed: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TBoundedQueue<Integer>; AFirst, ALast: Integer);
    property LastResult: TQueueWait read FLastResult;
    property Pushed: Integer read FPushed;
  end;

  { Drains until the queue closes, ticking off what it saw in a bitmap so a
    lost or duplicated value is provable rather than merely suspected. }
  TConsumer = class(TThread)
  strict private
    FQueue: TBoundedQueue<Integer>;
    FSeen: PIntegerArray;
    FSeenLen: Integer;
    FGot: Integer;
    FDuplicates: Integer;
    FLastResult: TQueueWait;
    FLock: TCriticalSection;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TBoundedQueue<Integer>; ASeen: PIntegerArray;
      ASeenLen: Integer; ALock: TCriticalSection);
    property Got: Integer read FGot;
    property Duplicates: Integer read FDuplicates;
    property LastResult: TQueueWait read FLastResult;
  end;

  { Parks in Push on a full queue, so Close can be shown to release it. }
  TBlockedProducer = class(TThread)
  strict private
    FQueue: TBoundedQueue<Integer>;
    FResult: TQueueWait;
    FFinished: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TBoundedQueue<Integer>);
    property Result_: TQueueWait read FResult;
    property Finished: Boolean read FFinished;
  end;

  TBlockedConsumer = class(TThread)
  strict private
    FQueue: TBoundedQueue<Integer>;
    FResult: TQueueWait;
    FFinished: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TBoundedQueue<Integer>);
    property Result_: TQueueWait read FResult;
    property Finished: Boolean read FFinished;
  end;

  { ------------------------------------------------------ runnable fixtures }

  TCountingTask = class(TInterfacedObject, IRunnable)
  strict private
    FCounter: THolder;
  public
    constructor Create(ACounter: THolder);
    procedure Run(const AToken: ICancellationToken);
  end;

  TFaultingTask = class(TInterfacedObject, IRunnable)
  public
    procedure Run(const AToken: ICancellationToken);
  end;

  TNonExceptionTask = class(TInterfacedObject, IRunnable)
  public
    procedure Run(const AToken: ICancellationToken);
  end;

  TPollingTask = class(TInterfacedObject, IRunnable)
  strict private
    FIterations: Integer;
  public
    procedure Run(const AToken: ICancellationToken);
    property Iterations: Integer read FIterations;
  end;

  TParkingTask = class(TInterfacedObject, IRunnable)
  strict private
    FWokeByCancel: Boolean;
  public
    procedure Run(const AToken: ICancellationToken);
    property WokeByCancel: Boolean read FWokeByCancel;
  end;

  TSelfJoinTask = class(TInterfacedObject, IRunnable)
  strict private
    FPool: TWorkerPool;
    FRaised: Boolean;
  public
    constructor Create(APool: TWorkerPool);
    procedure Run(const AToken: ICancellationToken);
    property Raised: Boolean read FRaised;
  end;

{ ---------------------------------------------------------------- fixtures }

constructor THolder.Create;
begin
  inherited Create;
  Counter.Init;
end;

constructor TBumper.Create(AHolder: THolder; AGate: TEvent; ARounds: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FHolder := AHolder;
  FGate := AGate;
  FRounds := ARounds;
end;

procedure TBumper.Execute;
var
  I: Integer;
begin
  { A start gate, so all the threads hammer at the same moment instead of
    starting staggered — which on a 2-core runner is the difference between
    observing a lost update and not. }
  FGate.WaitFor(BLOCK_MS);
  for I := 1 to FRounds do
    FHolder.Counter.Increment;
end;

constructor TProducer.Create(AQueue: TBoundedQueue<Integer>; AFirst, ALast: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
  FFirst := AFirst;
  FLast := ALast;
end;

procedure TProducer.Execute;
var
  I: Integer;
begin
  for I := FFirst to FLast do
  begin
    FLastResult := FQueue.Push(I, BLOCK_MS);
    if FLastResult <> qwOK then
      Exit;
    Inc(FPushed);
  end;
end;

constructor TConsumer.Create(AQueue: TBoundedQueue<Integer>; ASeen: PIntegerArray;
  ASeenLen: Integer; ALock: TCriticalSection);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
  FSeen := ASeen;
  FSeenLen := ASeenLen;
  FLock := ALock;
end;

procedure TConsumer.Execute;
var
  V: Integer;
begin
  repeat
    FLastResult := FQueue.Pop(V, BLOCK_MS);
    if FLastResult <> qwOK then
      Break;
    Inc(FGot);
    if (V >= 0) and (V < FSeenLen) then
    begin
      FLock.Enter;
      try
        if FSeen^[V] <> 0 then
          Inc(FDuplicates);
        FSeen^[V] := FSeen^[V] + 1;
      finally
        FLock.Leave;
      end;
    end;
  until False;
end;

constructor TBlockedProducer.Create(AQueue: TBoundedQueue<Integer>);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
end;

procedure TBlockedProducer.Execute;
begin
  FResult := FQueue.Push(999, BLOCK_MS);
  FFinished := True;
end;

constructor TBlockedConsumer.Create(AQueue: TBoundedQueue<Integer>);
var
  Ignored: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FQueue := AQueue;
  Ignored := 0;
  if Ignored <> 0 then ;
end;

procedure TBlockedConsumer.Execute;
var
  V: Integer;
begin
  FResult := FQueue.Pop(V, BLOCK_MS);
  FFinished := True;
end;

constructor TCountingTask.Create(ACounter: THolder);
begin
  inherited Create;
  FCounter := ACounter;
end;

procedure TCountingTask.Run(const AToken: ICancellationToken);
begin
  FCounter.Counter.Increment;
end;

procedure TFaultingTask.Run(const AToken: ICancellationToken);
begin
  raise Exception.Create('deliberate task failure');
end;

procedure TNonExceptionTask.Run(const AToken: ICancellationToken);
begin
  { `on E: Exception` does not catch this. The worker's bare `else` does. }
  raise TObject.Create;
end;

procedure TPollingTask.Run(const AToken: ICancellationToken);
begin
  while not AToken.IsCancelled do
  begin
    Inc(FIterations);
    Sleep(2);
  end;
end;

procedure TParkingTask.Run(const AToken: ICancellationToken);
begin
  { Parks instead of polling. A poll-only token could not release this, which is
    why ICancellationToken has WaitCancelled. }
  FWokeByCancel := AToken.WaitCancelled(BLOCK_MS);
end;

constructor TSelfJoinTask.Create(APool: TWorkerPool);
begin
  inherited Create;
  FPool := APool;
end;

procedure TSelfJoinTask.Run(const AToken: ICancellationToken);
begin
  try
    FPool.WaitIdle(BLOCK_MS);
  except
    on E: EPoolSelfJoin do
      FRaised := True;
  end;
end;

{ ============================================================ 1. the counter }

procedure TestAtomicBasics(R: TTestRunner);
var
  H: THolder;
begin
  R.Suite('Atomic counter — deterministic');
  H := THolder.Create;
  try
    R.AreEqual('starts at zero', 0, H.Counter.Value);
    R.AreEqual('Increment returns the NEW value', 1, H.Counter.Increment);
    R.AreEqual('Add returns the NEW value', 11, H.Counter.Add(10));
    R.AreEqual('Decrement returns the NEW value', 10, H.Counter.Decrement);
    { Exchange and CompareExchange return the value BEFORE, matching Delphi's
      TInterlocked so that porting code does not silently change meaning. }
    R.AreEqual('Exchange returns the OLD value', 10, H.Counter.Exchange(42));
    R.AreEqual('CompareExchange returns the OLD value', 42,
      H.Counter.CompareExchange(7, 42));
    R.AreEqual('CompareExchange swapped on a match', 7, H.Counter.Value);
    R.AreEqual('CompareExchange returns OLD on a mismatch too', 7,
      H.Counter.CompareExchange(99, 12345));
    R.AreEqual('a mismatched CompareExchange leaves the value alone', 7,
      H.Counter.Value);
  finally
    H.Free;
  end;
end;

procedure TestAtomicGuard(R: TTestRunner);
var
  Local: TAtomicCounter;
  Fired: Boolean;
begin
  R.Suite('Atomic counter — the guard (raises on purpose)');

  { An uninitialised local of a non-managed record is not zeroed; measured
    garbage on all three toolchains. The guard turns a silent wrong answer into
    a named failure at the first use. }
  Fired := False;
  try
    Local.Increment;
  except
    on E: Exception do
      Fired := True;
  end;
  R.IsTrue('an uninitialised local trips the guard', Fired);
end;

{ ================================================== 2. the queue, one thread }

procedure TestQueueSingleThread(R: TTestRunner);
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
  Raised: Boolean;
begin
  R.Suite('Bounded queue — single thread, deterministic');

  Raised := False;
  try
    Q := TBoundedQueue<Integer>.Create(0);
    Q.Free;
  except
    on E: EPoolArgument do
      Raised := True;
  end;
  R.IsTrue('a capacity below one is rejected', Raised);

  Q := TBoundedQueue<Integer>.Create(3);
  try
    R.AreEqual('capacity is what was asked for', 3, Q.Capacity);
    R.AreEqual('push into space', Ord(qwOK), Ord(Q.Push(1, 0)));
    R.AreEqual('push again', Ord(qwOK), Ord(Q.Push(2, 0)));
    R.AreEqual('push to the brim', Ord(qwOK), Ord(Q.Push(3, 0)));
    R.AreEqual('count reflects three items', 3, Q.Count);
    R.AreEqual('Push(x, 0) on a full queue is a try, and times out',
      Ord(qwTimeout), Ord(Q.Push(4, 0)));

    R.AreEqual('pop returns the first item', Ord(qwOK), Ord(Q.Pop(V, 0)));
    R.AreEqual('  and it is FIFO', 1, V);
    Q.Pop(V, 0);
    R.AreEqual('  still FIFO', 2, V);
    Q.Pop(V, 0);
    R.AreEqual('  and FIFO to the end', 3, V);
    R.AreEqual('Pop(x, 0) on an empty queue times out',
      Ord(qwTimeout), Ord(Q.Pop(V, 0)));

    { The ring must wrap without losing its ordering. }
    Q.Push(10, 0); Q.Push(11, 0); Q.Pop(V, 0); Q.Push(12, 0); Q.Push(13, 0);
    Q.Pop(V, 0); R.AreEqual('the ring wraps and stays ordered (1)', 11, V);
    Q.Pop(V, 0); R.AreEqual('the ring wraps and stays ordered (2)', 12, V);
    Q.Pop(V, 0); R.AreEqual('the ring wraps and stays ordered (3)', 13, V);
  finally
    Q.Free;
  end;
end;

procedure TestQueueCloseSemantics(R: TTestRunner);
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
begin
  R.Suite('Bounded queue — Close, deterministic');

  Q := TBoundedQueue<Integer>.Create(4);
  try
    Q.Push(1, 0);
    Q.Push(2, 0);
    Q.Close;
    R.IsTrue('IsClosed reports it', Q.IsClosed);
    { Items queued before Close are still the caller's to collect: drain first,
      report closure only when empty. }
    R.AreEqual('a closed queue still hands out what it holds',
      Ord(qwOK), Ord(Q.Pop(V, 0)));
    R.AreEqual('  in order', 1, V);
    Q.Pop(V, 0);
    R.AreEqual('closed AND empty finally reports qwClosed',
      Ord(qwClosed), Ord(Q.Pop(V, 0)));
    R.AreEqual('push after close is refused, not blocked',
      Ord(qwClosed), Ord(Q.Push(3, 0)));
    Q.Close;
    R.IsTrue('Close is idempotent', Q.IsClosed);
  finally
    Q.Free;
  end;

  Q := TBoundedQueue<Integer>.Create(4);
  try
    Q.Push(1, 0); Q.Push(2, 0); Q.Push(3, 0);
    R.AreEqual('DrainAndClose reports what it discarded', 3, Q.DrainAndClose);
    R.IsTrue('  and closes', Q.IsClosed);
    R.AreEqual('  leaving nothing', 0, Q.Count);
  finally
    Q.Free;
  end;
end;

{ ================================== 3. the queue, contended — still bounded }

procedure TestQueueBlocksAndTimesOut(R: TTestRunner);
var
  Q: TBoundedQueue<Integer>;
  V: Integer;
  T0: UInt64;
  Waited: Cardinal;
begin
  R.Suite('Bounded queue — blocking is real');

  Q := TBoundedQueue<Integer>.Create(1);
  try
    R.Begins('an empty Pop with a deadline waits, then times out');
    T0 := Ticks;
    R.AreEqual('an empty Pop with a deadline waits, then times out',
      Ord(qwTimeout), Ord(Q.Pop(V, 300)));
    Waited := Elapsed(T0);
    R.IsTrue('  and it really waited (>= 250 ms)', Waited >= 250);
    { A spinning implementation would leave WaitCount at zero. }
    R.IsTrue('  by blocking on an event, not spinning', Q.WaitCount > 0);

    Q.Push(1, 0);
    R.Begins('a full Push with a deadline waits, then times out');
    T0 := Ticks;
    R.AreEqual('a full Push with a deadline waits, then times out',
      Ord(qwTimeout), Ord(Q.Push(2, 300)));
    R.IsTrue('  and it really waited (>= 250 ms)', Elapsed(T0) >= 250);
  finally
    Q.Free;
  end;
end;

procedure TestCloseReleasesWaiters(R: TTestRunner);
const
  { Close has to release a parked thread PROMPTLY. This bound is what the test
    actually turns on, and the reason deserves stating.

    Removing the wakeup does not hang this queue: the parked thread's WaitFor
    expires, the loop re-checks the predicate under the lock, sees FClosed and
    returns qwClosed. Correctness comes from the bounded re-check loop, not from
    the events — the events are what make the release immediate instead of
    "whenever your timeout happens to run out".

    So a test that only checked the RESULT would pass with the wakeup removed,
    just five seconds later, and PROVE_NOWAKE would prove nothing. Latency is
    the property the events provide, so latency is what is asserted. }
  RELEASE_MS = 1000;
var
  Q: TBoundedQueue<Integer>;
  Blocked: TBlockedProducer;
  Waiting: TBlockedConsumer;
  T0: UInt64;
  Took: Cardinal;
begin
  R.Suite('Bounded queue — Close releases parked threads promptly');

  { The deadlock that bounded-queue implementations usually ship with: a
    producer parked on a full queue when the queue is closed. }
  Q := TBoundedQueue<Integer>.Create(1);
  try
    Q.Push(1, 0);
    Blocked := TBlockedProducer.Create(Q);
    try
      R.Begins('Close releases a producer parked on a full queue');
      Blocked.Start;
      Sleep(SETTLE_MS);
      R.AreEqual('the producer is parked before Close', 1, Q.WaitingProducers);

      T0 := Ticks;
      Q.Close;
      Blocked.WaitFor;
      Took := Elapsed(T0);

      R.IsTrue('Close releases a producer parked on a full queue',
        Blocked.Finished);
      R.AreEqual('  and it reports qwClosed', Ord(qwClosed),
        Ord(Blocked.Result_));
      R.IsTrue('  within ' + IntToStr(RELEASE_MS) + ' ms, not at its own ' +
        'timeout (took ' + IntToStr(Took) + ' ms)', Took < RELEASE_MS);
    finally
      Blocked.Free;
    end;
  finally
    Q.Free;
  end;

  Q := TBoundedQueue<Integer>.Create(1);
  try
    Waiting := TBlockedConsumer.Create(Q);
    try
      R.Begins('Close releases a consumer parked on an empty queue');
      Waiting.Start;
      Sleep(SETTLE_MS);
      R.AreEqual('the consumer is parked before Close', 1, Q.WaitingConsumers);

      T0 := Ticks;
      Q.Close;
      Waiting.WaitFor;
      Took := Elapsed(T0);

      R.IsTrue('Close releases a consumer parked on an empty queue',
        Waiting.Finished);
      R.AreEqual('  and it reports qwClosed', Ord(qwClosed),
        Ord(Waiting.Result_));
      R.IsTrue('  within ' + IntToStr(RELEASE_MS) + ' ms, not at its own ' +
        'timeout (took ' + IntToStr(Took) + ' ms)', Took < RELEASE_MS);
    finally
      Waiting.Free;
    end;
  finally
    Q.Free;
  end;
end;

procedure TestQueueProducerConsumerExactness(R: TTestRunner);
const
  TOTAL = 4000;
  PRODUCERS = 3;
  CONSUMERS = 3;
var
  Q: TBoundedQueue<Integer>;
  Seen: array of Integer;
  Lock: TCriticalSection;
  Prod: array[0..PRODUCERS - 1] of TProducer;
  Cons: array[0..CONSUMERS - 1] of TConsumer;
  I, Per, GotTotal, Dups, Missing: Integer;
begin
  R.Suite('Bounded queue — nothing lost, nothing duplicated');

  SetLength(Seen, TOTAL);
  Lock := TCriticalSection.Create;
  Q := TBoundedQueue<Integer>.Create(16);
  try
    Per := TOTAL div PRODUCERS;
    for I := 0 to PRODUCERS - 1 do
      Prod[I] := TProducer.Create(Q, I * Per, (I + 1) * Per - 1);
    for I := 0 to CONSUMERS - 1 do
      Cons[I] := TConsumer.Create(Q, PIntegerArray(Seen), TOTAL, Lock);

    R.Begins('a contended producer/consumer run completes');
    for I := 0 to CONSUMERS - 1 do
      Cons[I].Start;
    for I := 0 to PRODUCERS - 1 do
      Prod[I].Start;

    for I := 0 to PRODUCERS - 1 do
      Prod[I].WaitFor;
    { Close only after every producer is done, so the consumers drain and then
      see qwClosed. This is the shutdown handshake the pool relies on. }
    Q.Close;
    for I := 0 to CONSUMERS - 1 do
      Cons[I].WaitFor;

    GotTotal := 0;
    Dups := 0;
    for I := 0 to CONSUMERS - 1 do
    begin
      Inc(GotTotal, Cons[I].Got);
      Inc(Dups, Cons[I].Duplicates);
    end;

    { Only over the range actually produced. TOTAL div PRODUCERS truncates, so
      the producers cover 0 .. PRODUCERS*Per-1 and the tail of the bitmap is
      never written — checking the whole array would report a gap the library
      did not cause. }
    Missing := 0;
    for I := 0 to PRODUCERS * Per - 1 do
      if Seen[I] <> 1 then
        Inc(Missing);

    R.AreEqual('every item was delivered exactly once', PRODUCERS * Per, GotTotal);
    R.AreEqual('no duplicates', 0, Dups);
    R.AreEqual('no gaps in the bitmap', 0, Missing);
    R.AreEqual('the queue ends empty', 0, Q.Count);

    for I := 0 to PRODUCERS - 1 do
      Prod[I].Free;
    for I := 0 to CONSUMERS - 1 do
      Cons[I].Free;
  finally
    Q.Free;
    Lock.Free;
  end;
end;

{ ================================================================ 4. worker }

procedure TestWorkerLifecycle(R: TTestRunner);
var
  H: THolder;
  W: TWorker;
  Task: IRunnable;
  Raised: Boolean;
begin
  R.Suite('Worker — lifecycle, deterministic');

  H := THolder.Create;
  try
    Task := TCountingTask.Create(H);
    W := TWorker.Create(Task);
    try
      R.AreEqual('a new worker is merely created', Ord(wsCreated), Ord(W.State));
      W.Start;
      R.IsTrue('it joins', W.WaitFor(BLOCK_MS));
      R.AreEqual('and reports finished', Ord(wsFinished), Ord(W.State));
      R.AreEqual('the task ran exactly once', 1, H.Counter.Value);
      R.IsFalse('nothing faulted', W.Faulted);
    finally
      W.Free;
    end;

    { Hazard 1: destroying a never-started worker must not hang or leak. }
    Task := TCountingTask.Create(H);
    W := TWorker.Create(Task);
    R.Begins('a worker that was never started can be freed');
    W.Free;
    R.IsTrue('a worker that was never started can be freed', True);

    Task := TCountingTask.Create(H);
    W := TWorker.Create(Task);
    try
      W.Start;
      Raised := False;
      try
        W.Start;
      except
        on E: EPoolState do
          Raised := True;
      end;
      R.IsTrue('a second Start is refused', Raised);
      W.WaitFor(BLOCK_MS);
    finally
      W.Free;
    end;
  finally
    H.Free;
  end;
end;

procedure TestWorkerFaults(R: TTestRunner);
var
  W: TWorker;
  Task: IRunnable;
begin
  R.Suite('Worker — faults are captured, not swallowed');

  { THE FLAGSHIP. Under -dPROVE_SWALLOW these four assertions fail on every run,
    on any core count, on any OS: the exception unwinds into the RTL, parks in
    TThread.FatalException where nothing reads it, and the work disappears. }
  Task := TFaultingTask.Create;
  W := TWorker.Create(Task);
  try
    W.Start;
    R.IsTrue('a faulting worker still joins', W.WaitFor(BLOCK_MS));
    R.IsTrue('the fault is visible', W.Faulted);
    R.AreEqual('the state says faulted', Ord(wsFaulted), Ord(W.State));
    R.AreEqual('the exception class is kept', 'Exception', W.FaultClassName);
    R.AreEqual('the message is kept', 'deliberate task failure', W.FaultMessage);
  finally
    W.Free;
  end;

  { `on E: Exception` does not catch this; the bare `else` does. }
  Task := TNonExceptionTask.Create;
  W := TWorker.Create(Task);
  try
    W.Start;
    R.IsTrue('a non-Exception raise still joins', W.WaitFor(BLOCK_MS));
    R.IsTrue('a non-Exception raise is caught too', W.Faulted);
    R.AreEqual('and is described as best it can be', '(non-Exception)',
      W.FaultClassName);
  finally
    W.Free;
  end;
end;

procedure TestWorkerCancellation(R: TTestRunner);
var
  W: TWorker;
  Polling: TPollingTask;
  Parking: TParkingTask;
  Task: IRunnable;
  T0: UInt64;
begin
  R.Suite('Worker — cancellation is cooperative');

  Polling := TPollingTask.Create;
  Task := Polling;
  W := TWorker.Create(Task);
  try
    R.Begins('a polling task stops when cancelled');
    W.Start;
    Sleep(SETTLE_MS);
    W.Cancel;
    R.IsTrue('a polling task stops when cancelled', W.WaitFor(BLOCK_MS));
    R.IsTrue('  having done some work first', Polling.Iterations > 0);
  finally
    W.Free;
  end;

  { The reason ICancellationToken is an interface with WaitCancelled rather than
    a Boolean poll: a task parked in a wait cannot poll, so a poll-only token
    would make Cancel-then-join a guaranteed deadlock. }
  Parking := TParkingTask.Create;
  Task := Parking;
  W := TWorker.Create(Task);
  try
    R.Begins('a PARKED task is released by cancellation');
    W.Start;
    Sleep(SETTLE_MS);
    T0 := Ticks;
    W.Cancel;
    R.IsTrue('a PARKED task is released by cancellation', W.WaitFor(BLOCK_MS));
    R.IsTrue('  it woke because of the cancel', Parking.WokeByCancel);
    R.IsTrue('  promptly, not by its own timeout', Elapsed(T0) < 2000);
  finally
    W.Free;
  end;
end;

{ ================================================================== 5. pool }

procedure TestPoolAccounting(R: TTestRunner);
const
  N = 500;
var
  P: TWorkerPool;
  H: THolder;
  I, Accepted: Integer;
begin
  R.Suite('Pool — the accounting invariant');

  H := THolder.Create;
  P := TWorkerPool.Create(4, 32);
  try
    R.AreEqual('the pool has the workers it was asked for', 4, P.WorkerCount);

    R.Begins('submitting ' + IntToStr(N) + ' items');
    Accepted := 0;
    for I := 1 to N do
      if P.Submit(TCountingTask.Create(H), BLOCK_MS) = qwOK then
        Inc(Accepted);
    R.AreEqual('every submission was accepted', N, Accepted);

    R.Begins('waiting for the pool to go idle');
    R.IsTrue('the pool goes idle', P.WaitIdle(BLOCK_MS));

    R.AreEqual('every task ran exactly once', N, H.Counter.Value);
    R.AreEqual('Submitted counts them all', N, P.Submitted);
    R.AreEqual('Completed counts them all', N, P.Completed);
    R.AreEqual('nothing faulted', 0, P.Faulted);
    R.AreEqual('nothing was dropped', 0, P.Dropped);
    R.AreEqual('nothing is left pending', 0, P.Pending);
    R.AreEqual('nothing is in flight', 0, P.InFlight);

    { The invariant, which is a race-free proof that work was neither lost nor
      run twice — much stronger than "a counter reached N". }
    R.AreEqual('Submitted = Completed + Faulted + Dropped',
      P.Submitted, P.Completed + P.Faulted + P.Dropped);

    R.Begins('shutting down');
    R.IsTrue('Shutdown joins every worker', P.Shutdown(BLOCK_MS));
    R.IsTrue('and it reports itself shut down', P.IsShutdown);
    R.AreEqual('Submit after shutdown is refused, not blocked',
      Ord(qwClosed), Ord(P.Submit(TCountingTask.Create(H), 0)));
  finally
    P.Free;
    H.Free;
  end;
end;

procedure TestPoolFaultsAndDrops(R: TTestRunner);
var
  P: TWorkerPool;
  H: THolder;
  I: Integer;
begin
  R.Suite('Pool — a faulting task does not shrink the pool');

  H := THolder.Create;
  P := TWorkerPool.Create(2, 16);
  try
    for I := 1 to 5 do
      P.Submit(TFaultingTask.Create, BLOCK_MS);
    { If a fault killed its worker, the pool would silently shrink and these
      later items would never run. }
    for I := 1 to 5 do
      P.Submit(TCountingTask.Create(H), BLOCK_MS);

    R.Begins('a pool with faulting tasks still goes idle');
    R.IsTrue('a pool with faulting tasks still goes idle', P.WaitIdle(BLOCK_MS));
    R.AreEqual('the faults were counted', 5, P.Faulted);
    R.AreEqual('the good tasks still ran', 5, P.Completed);
    R.AreEqual('and they really ran', 5, H.Counter.Value);
    R.AreEqual('Submitted = Completed + Faulted + Dropped',
      P.Submitted, P.Completed + P.Faulted + P.Dropped);
    P.Shutdown(BLOCK_MS);
  finally
    P.Free;
    H.Free;
  end;

  R.Suite('Pool — ShutdownNow accounts for abandoned work');
  H := THolder.Create;
  { One worker, small queue, so work backs up and there is something to abandon. }
  P := TWorkerPool.Create(1, 64);
  try
    for I := 1 to 40 do
      P.Submit(TCountingTask.Create(H), 0);

    R.Begins('ShutdownNow');
    R.IsTrue('ShutdownNow joins', P.ShutdownNow(BLOCK_MS));
    R.AreEqual('and the invariant still balances',
      P.Submitted, P.Completed + P.Faulted + P.Dropped);
    R.IsTrue('some work was abandoned rather than silently lost',
      P.Dropped >= 0);
  finally
    P.Free;
    H.Free;
  end;
end;

procedure TestPoolSelfJoin(R: TTestRunner);
var
  P: TWorkerPool;
  Task: TSelfJoinTask;
  Ref: IRunnable;
begin
  R.Suite('Pool — waiting on yourself raises instead of hanging');

  P := TWorkerPool.Create(2, 8);
  try
    Task := TSelfJoinTask.Create(P);
    Ref := Task;
    R.Begins('a task that waits on its own pool');
    P.Submit(Ref, BLOCK_MS);
    R.IsTrue('the pool goes idle rather than deadlocking', P.WaitIdle(BLOCK_MS));
    R.IsTrue('and the task got EPoolSelfJoin', Task.Raised);
    P.Shutdown(BLOCK_MS);
  finally
    P.Free;
  end;
end;

{ ====================================== 6. statistical: the lost-update race }

procedure TestAtomicUnderContention(R: TTestRunner);
const
  THREADS = 8;
  ROUNDS = 250000;
var
  H: THolder;
  Gate: TEvent;
  T: array[0..THREADS - 1] of TBumper;
  I: Integer;
begin
  R.Suite('Atomic counter — under contention (STATISTICAL)');

  { The only proof in this repo that is not airtight: it needs more than one
    core to observe a lost update, and the CI runner has two. The window is
    widened deliberately in the PROVE_RACE_ATOMIC build for that reason, and CI
    retries that build. This test itself, in a normal build, is exact. }
  H := THolder.Create;
  Gate := TEvent.Create(nil, True, False, '');
  try
    for I := 0 to THREADS - 1 do
      T[I] := TBumper.Create(H, Gate, ROUNDS);
    for I := 0 to THREADS - 1 do
      T[I].Start;

    R.Begins('8 threads x 250k interlocked increments');
    Sleep(SETTLE_MS);
    Gate.SetEvent;   { start them all at once }
    for I := 0 to THREADS - 1 do
      T[I].WaitFor;

    R.AreEqual('not one increment is lost', THREADS * ROUNDS, H.Counter.Value);

    for I := 0 to THREADS - 1 do
      T[I].Free;
  finally
    Gate.Free;
    H.Free;
  end;
end;

{ ==================================================================== entry }

procedure RunTests(ARunner: TTestRunner; ARunGuardTests: Boolean);
begin
  { Deterministic first. }
  TestAtomicBasics(ARunner);
  TestQueueSingleThread(ARunner);
  TestQueueCloseSemantics(ARunner);
  TestQueueBlocksAndTimesOut(ARunner);
  TestCloseReleasesWaiters(ARunner);
  TestQueueProducerConsumerExactness(ARunner);
  TestWorkerLifecycle(ARunner);
  TestWorkerFaults(ARunner);
  TestWorkerCancellation(ARunner);
  TestPoolAccounting(ARunner);
  TestPoolFaultsAndDrops(ARunner);
  TestPoolSelfJoin(ARunner);

  { Then the one that raises on purpose, so a debugger session can skip it. }
  if ARunGuardTests then
    TestAtomicGuard(ARunner);

  { Statistical last, and labelled. }
  TestAtomicUnderContention(ARunner);
end;

end.
