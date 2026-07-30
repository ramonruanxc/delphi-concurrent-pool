{
  ConcurrentPool — a bounded blocking queue.

  Three decisions carry this unit, and they are the reason it is hand-rolled
  rather than a counter wrapped around somebody else's container.

  1. A RING, not a general container with a size check bolted on. In a library
     whose selling point is a bounded queue, the bound belongs in the storage.
     It also puts the release of a vacated slot in plain sight — PopLocked ends
     by writing an empty value back — instead of leaving it as a property of a
     container you have to go and read.

  2. TWO MANUAL-RESET EVENTS whose signalled state MIRRORS THE PREDICATE,
     maintained only under the lock. Not a style choice:

       - An auto-reset event is a binary latch. Two pushes in quick succession
         wake one consumer, not two, and the second item sits unnoticed.
         (Measured: two SetEvent calls, then two WaitFor(0) — signalled, then
         timeout.)
       - Close has to release N parked threads at once, and SetEvent on an
         auto-reset event releases exactly one.
       - It removes the classic lost wakeup by construction. Between the
         unlock and the WaitFor there is a window; an item arriving in that
         window sets FNotEmpty and it STAYS set, so the wait returns
         immediately. That argument is only available because the events carry
         state rather than transitions.

     Measured on both targets: one SetEvent on a manual-reset event released
     four parked waiters, and a waiter arriving afterwards passed without any
     further signal.

  3. Close is a LATCH. Once closed, both events are set and never reset again,
     so a thread that arrives after Close still finds a signalled event. This is
     what makes "producer blocked on a full queue, then Close" return qwClosed
     instead of hanging — the deadlock that bounded-queue implementations
     usually ship with.

  Structural rule, held throughout: every public method takes the lock exactly
  once and does its work through non-locking strict-private helpers. Re-entrancy
  is never relied on, so it does not matter whether TCriticalSection is a
  recursive mutex on any given platform. A Count that locked, called from inside
  a Push that already held the lock, would work on Windows and deadlock on
  Linux — the worst possible split, because the Delphi demo would look fine.
}
unit ConcurrentPool.Queue;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils, SyncObjs{$ELSE}System.SysUtils, System.SyncObjs{$ENDIF},
  ConcurrentPool.Types,
  ConcurrentPool.Atomic;

type
  TBoundedQueue<T> = class
  strict private
    FItems: array of T;
    { A class field, so it is zero-initialised: assigning it to a slot releases
      whatever managed reference the slot held, without needing Default(T). }
    FEmptySlot: T;
    FCapacity: Integer;
    FHead: Integer;
    FCount: Integer;
    FClosed: Boolean;
    FLock: TCriticalSection;
    FNotEmpty: TEvent;
    FNotFull: TEvent;
    FWaitingProducers: TAtomicCounter;
    FWaitingConsumers: TAtomicCounter;
    FWaits: TAtomicCounter;

    procedure Lock; inline;
    procedure Unlock; inline;

    { The whole signalling policy, in one place, called on every state change
      while the lock is held. }
    procedure RefreshSignalsLocked;
    procedure PushLocked(const AItem: T);
    procedure PopLocked(out AItem: T);
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;

    { Blocks while the queue is full, up to ATimeoutMs measured as ONE deadline
      across all wakes. Push(item, 0) is the non-blocking try form.

      AItem is taken BY VALUE rather than as const. For a managed T — an
      interface, a string — a const parameter takes no reference, so an item
      created inline and then REFUSED by a full or closed queue would never be
      referenced by anything and would never be released. By value it holds a
      reference for the duration of the call. For a plain T the copy is a
      register move. }
    function Push(AItem: T; ATimeoutMs: Cardinal): TQueueWait;

    { Blocks while the queue is empty. Items already queued are drained before
      qwClosed is reported, so nothing is lost by a Close that races a Pop. }
    function Pop(out AItem: T; ATimeoutMs: Cardinal): TQueueWait;

    { Idempotent, callable from any thread, never raises. Wakes every parked
      producer and consumer. }
    procedure Close;

    { Close, then release every queued item. Returns how many were dropped, so a
      caller can account for abandoned work. }
    function DrainAndClose: Integer;

    { ADVISORY ONLY: true when read, potentially stale by the time you act on
      it. Meaningful in a test after the producers have joined; not a basis for
      a decision. }
    function Count: Integer;
    function Capacity: Integer;
    function IsClosed: Boolean;

    { Exposed so the suite can assert on a FACT instead of sleeping and hoping.
      WaitCount also proves the queue blocks rather than spins: a spinning
      implementation would leave it at zero. }
    function WaitingConsumers: Integer;
    function WaitingProducers: Integer;
    function WaitCount: Integer;
  end;

implementation

constructor TBoundedQueue<T>.Create(ACapacity: Integer);
begin
  inherited Create;

  { The counters are initialised FIRST, before anything that can raise.

    A constructor that raises still has its destructor called on the
    half-built object, and Destroy reads these counters — so if they were
    initialised after the capacity check, rejecting a bad capacity would trip
    the counter guard inside Destroy instead of surfacing the EPoolArgument the
    caller is waiting for. Init cannot fail, so it belongs before anything that
    can. }
  FWaitingProducers.Init;
  FWaitingConsumers.Init;
  FWaits.Init;

  if ACapacity < 1 then
    raise EPoolArgument.CreateFmt(
      'Queue capacity must be at least 1, got %d.', [ACapacity]);

  FCapacity := ACapacity;
  SetLength(FItems, ACapacity);
  FHead := 0;
  FCount := 0;
  FClosed := False;

  FLock := TCriticalSection.Create;
  { Manual-reset, initial state matching the predicate: nothing queued, so
    NotEmpty is unset; nothing stored, so NotFull is set. }
  FNotEmpty := TEvent.Create(nil, True, False, '');
  FNotFull := TEvent.Create(nil, True, True, '');
end;

destructor TBoundedQueue<T>.Destroy;
var
  I: Integer;
begin
  { Close first, so a thread still parked in Push or Pop is released and can
    leave before its wait object disappears. }
  if FLock <> nil then
    Close;

  { Safe on a half-built object because the counters are initialised before
    anything in the constructor can raise. }
  Assert(FWaitingConsumers.Value + FWaitingProducers.Value = 0,
    'TBoundedQueue destroyed while threads were still parked in Push or Pop. ' +
    'Join your producers and consumers first.');

  { Release every live slot. The ring owns its references until they are handed
    out, so dropping them here is the queue's job, not the caller's. }
  for I := 0 to High(FItems) do
    FItems[I] := FEmptySlot;

  FNotFull.Free;
  FNotEmpty.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TBoundedQueue<T>.Lock;
begin
  {$IFNDEF PROVE_RACE_QUEUE}
  FLock.Enter;
  {$ENDIF}
end;

procedure TBoundedQueue<T>.Unlock;
begin
  {$IFNDEF PROVE_RACE_QUEUE}
  FLock.Leave;
  {$ENDIF}
end;

procedure TBoundedQueue<T>.RefreshSignalsLocked;
begin
  if FClosed then
  begin
    { Latched: set once, never reset, so a late arrival still sees them
      signalled. }
    {$IFNDEF PROVE_NOWAKE}
    FNotEmpty.SetEvent;
    FNotFull.SetEvent;
    {$ENDIF}
    Exit;
  end;

  if FCount > 0 then
    FNotEmpty.SetEvent
  else
    FNotEmpty.ResetEvent;

  if FCount < FCapacity then
    FNotFull.SetEvent
  else
    FNotFull.ResetEvent;
end;

procedure TBoundedQueue<T>.PushLocked(const AItem: T);
var
  Tail: Integer;
begin
  Tail := (FHead + FCount) mod FCapacity;
  FItems[Tail] := AItem;
  Inc(FCount);
end;

procedure TBoundedQueue<T>.PopLocked(out AItem: T);
begin
  AItem := FItems[FHead];
  { Clear the vacated slot, every time. A ring that leaves the old value behind
    holds a managed reference alive until the slot is reused. }
  FItems[FHead] := FEmptySlot;
  FHead := (FHead + 1) mod FCapacity;
  Dec(FCount);
end;

function TBoundedQueue<T>.Push(AItem: T; ATimeoutMs: Cardinal): TQueueWait;
var
  Start: UInt64;
  Wait: Cardinal;
begin
  Start := Ticks;
  { A loop, never a single `if`: a wake is a hint that the predicate MIGHT hold,
    not a guarantee, because another thread can win the slot in between. }
  repeat
    Lock;
    try
      if FClosed then
        Exit(qwClosed);
      if FCount < FCapacity then
      begin
        PushLocked(AItem);
        RefreshSignalsLocked;
        Exit(qwOK);
      end;
    finally
      Unlock;
    end;

    Wait := Remaining(Start, ATimeoutMs);
    if Wait = 0 then
      Exit(qwTimeout);

    FWaitingProducers.Increment;
    FWaits.Increment;
    try
      FNotFull.WaitFor(Wait);
    finally
      FWaitingProducers.Decrement;
    end;
  until False;
end;

function TBoundedQueue<T>.Pop(out AItem: T; ATimeoutMs: Cardinal): TQueueWait;
var
  Start: UInt64;
  Wait: Cardinal;
begin
  AItem := FEmptySlot;
  Start := Ticks;
  repeat
    Lock;
    try
      { Drain before reporting closure: an item queued before Close is still
        the caller's to collect. }
      if FCount > 0 then
      begin
        PopLocked(AItem);
        RefreshSignalsLocked;
        Exit(qwOK);
      end;
      if FClosed then
        Exit(qwClosed);
    finally
      Unlock;
    end;

    Wait := Remaining(Start, ATimeoutMs);
    if Wait = 0 then
      Exit(qwTimeout);

    FWaitingConsumers.Increment;
    FWaits.Increment;
    try
      FNotEmpty.WaitFor(Wait);
    finally
      FWaitingConsumers.Decrement;
    end;
  until False;
end;

procedure TBoundedQueue<T>.Close;
begin
  Lock;
  try
    if FClosed then
      Exit;
    FClosed := True;
    RefreshSignalsLocked;
  finally
    Unlock;
  end;
end;

function TBoundedQueue<T>.DrainAndClose: Integer;
var
  Dropped: Integer;
  Ignored: T;
begin
  Dropped := 0;
  Lock;
  try
    FClosed := True;
    while FCount > 0 do
    begin
      PopLocked(Ignored);
      Inc(Dropped);
    end;
    { Release the last one the loop handed out. }
    Ignored := FEmptySlot;
    RefreshSignalsLocked;
  finally
    Unlock;
  end;
  Result := Dropped;
end;

function TBoundedQueue<T>.Count: Integer;
begin
  Lock;
  try
    Result := FCount;
  finally
    Unlock;
  end;
end;

function TBoundedQueue<T>.Capacity: Integer;
begin
  { Immutable after construction, so no lock is needed. }
  Result := FCapacity;
end;

function TBoundedQueue<T>.IsClosed: Boolean;
begin
  Lock;
  try
    Result := FClosed;
  finally
    Unlock;
  end;
end;

function TBoundedQueue<T>.WaitingConsumers: Integer;
begin
  Result := FWaitingConsumers.Value;
end;

function TBoundedQueue<T>.WaitingProducers: Integer;
begin
  Result := FWaitingProducers.Value;
end;

function TBoundedQueue<T>.WaitCount: Integer;
begin
  Result := FWaits.Value;
end;

end.
