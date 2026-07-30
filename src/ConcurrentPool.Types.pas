{
  ConcurrentPool — shared vocabulary.

  Queue and Pool both need the wait result; Worker and Pool both need IRunnable.
  Declaring those in Worker would force Queue to depend on Worker and turn the
  dependency graph into a diamond. This unit keeps it a line:

    Types -> Atomic -> Queue -> Worker -> Pool

  Nothing here depends on anything else in the library.
}
unit ConcurrentPool.Types;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils, Classes{$ELSE}System.SysUtils, System.Classes{$ENDIF};

const
  { Valid for library internals. Deliberately NOT used anywhere in tests: every
    wait in the suite is bounded, because a hazard in this library fails by
    blocking, and turning a hang into a named assertion failure is part of the
    proof strategy rather than CI polish. }
  WAIT_INFINITE = Cardinal($FFFFFFFF);

type
  { Three outcomes, because two cannot be acted upon. qwTimeout means "try
    again", qwClosed means "stop, forever". A Boolean collapses them and makes
    the pool's drain loop unimplementable: it could not tell a slow producer
    from a shut-down queue. }
  TQueueWait = (qwOK, qwTimeout, qwClosed);

  TWorkerState = (wsCreated, wsRunning, wsFinished, wsFaulted);

  EConcurrentPool = class(Exception);
  { Capacity or worker count below one. }
  EPoolArgument = class(EConcurrentPool);
  { Starting something that is already started. }
  EPoolState = class(EConcurrentPool);
  { Joining or shutting down from inside the very thread being waited on. Raised
    rather than deadlocking: a hang gives no stack, no message, and burns a CI
    runner until the job times out. }
  EPoolSelfJoin = class(EConcurrentPool);

  { Read-only by construction: a task can observe cancellation, never cause it.

    WaitCancelled is the reason this is an interface rather than a Boolean
    function. A poll-only token cannot unblock a runnable that is parked in a
    wait, so Cancel followed by a join would deadlock by design — the task would
    never reach its next poll. A task that has to wait for something waits on
    the token too. }
  ICancellationToken = interface
    ['{B1B3D0A6-7C2E-4B0A-9E31-6C7A1D5E8A11}']
    function IsCancelled: Boolean;
    { True when cancellation happened during the wait; False on timeout. }
    function WaitCancelled(ATimeoutMs: Cardinal): Boolean;
  end;

  IRunnable = interface
    ['{2E9F4C1D-55A8-4E7B-8D22-9F3B6A0C4D22}']
    procedure Run(const AToken: ICancellationToken);
  end;

  TRunMethod = procedure(const AToken: ICancellationToken) of object;

  { The one ergonomics concession, and the reason there is no anonymous-method
    overload: Free Pascal 3.2 has no `reference to procedure` at all (measured —
    it does not even parse), so a portable callback is either an interface or a
    method pointer. Without this adapter every one-line task would cost a class,
    a constructor and a field.

    A refcounted interface rather than a bare method pointer is also what makes
    the queue's ownership of pending work self-evident: a queued `of object`
    carries no lifetime, and abandoning one on shutdown would be a
    use-after-free waiting to happen. }
  TMethodRunnable = class(TInterfacedObject, IRunnable)
  strict private
    FMethod: TRunMethod;
  public
    constructor Create(const AMethod: TRunMethod);
    procedure Run(const AToken: ICancellationToken);
  end;

function AsRunnable(const AMethod: TRunMethod): IRunnable;

{ Monotonic clock. A wall clock is wrong here — NTP and DST can move it
  backwards mid-wait — so this is GetTickCount64 on both compilers, reached
  through TThread on Delphi so the core needs no platform unit. }
function Ticks: UInt64;

{ Milliseconds since AStart.

  Deliberately does NOT rely on wraparound arithmetic. Delphi enables overflow
  checking in a default debug configuration and Free Pascal does not, so an
  expression that wraps would raise EIntOverflow on one compiler and return a
  value on the other — a difference decided by a build switch, which is no basis
  for a timeout. Instead the subtraction stays in UInt64, where a 64-bit
  millisecond counter cannot realistically roll over, and the backwards case is
  handled with a comparison rather than left to wrap. }
function Elapsed(AStart: UInt64): Cardinal;

{ What is left of ATimeoutMs, given a wait that started at AStart. Zero means
  expired; WAIT_INFINITE passes straight through. This is what gives every
  blocking call ONE deadline rather than a fresh timeout on each wake — the
  difference between Pop(100) meaning "at most 100 ms" and meaning "100 ms per
  spurious wake, forever". }
function Remaining(AStart: UInt64; ATimeoutMs: Cardinal): Cardinal;

implementation

{ TMethodRunnable }

constructor TMethodRunnable.Create(const AMethod: TRunMethod);
begin
  inherited Create;
  if not Assigned(AMethod) then
    raise EPoolArgument.Create('TMethodRunnable requires a method.');
  FMethod := AMethod;
end;

procedure TMethodRunnable.Run(const AToken: ICancellationToken);
begin
  FMethod(AToken);
end;

function AsRunnable(const AMethod: TRunMethod): IRunnable;
begin
  Result := TMethodRunnable.Create(AMethod);
end;

function Ticks: UInt64;
begin
  {$IFDEF FPC}
  Result := SysUtils.GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

function Elapsed(AStart: UInt64): Cardinal;
var
  Current: UInt64;
  Gone: UInt64;
begin
  Current := Ticks;

  { A clock that appears to run backwards means "no time has passed", not a
    64-bit underflow. Measured 0 backwards steps over 200k samples on both
    targets, so this is insurance rather than a workaround — but it is what lets
    the function be correct regardless of the overflow-check setting. }
  if Current <= AStart then
    Exit(0);

  Gone := Current - AStart;
  if Gone > High(Cardinal) then
    Result := High(Cardinal)
  else
    Result := Cardinal(Gone);
end;

function Remaining(AStart: UInt64; ATimeoutMs: Cardinal): Cardinal;
var
  Gone: Cardinal;
begin
  if ATimeoutMs = WAIT_INFINITE then
    Exit(WAIT_INFINITE);

  Gone := Elapsed(AStart);
  if Gone >= ATimeoutMs then
    Result := 0
  else
    Result := ATimeoutMs - Gone;
end;

end.
