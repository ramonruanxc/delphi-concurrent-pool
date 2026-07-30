{
  ConcurrentPool — a worker that owns its thread.

  This unit exists to remove five hazards that a bare TThread hands you, each of
  which is a bug people actually ship.

  1. NO THREAD UNTIL Start. `TThread.Create(True)` followed by a destroy — the
     never-started suspended thread — is a classic hang or leak depending on the
     RTL version. Here Create allocates nothing but fields, so destroying a
     worker that was never started has nothing to wait on and nothing to free.

  2. Destroy JOINS, unconditionally. Execute reads FRunnable, FSource and FLock;
     abandoning a live thread and then freeing the worker is a use-after-free,
     and TerminateThread leaks whatever locks the thread held and can strand the
     heap lock. So cancellation is cooperative, a runnable that never checks its
     token cannot be stopped, and Destroy blocks until Run returns. WaitFor with
     a timeout exists so a CALLER can decide what to do about a slow worker; a
     destructor is not offered that choice. Blocking in a destructor is the
     lesser evil against freeing memory a running thread is reading.

  3. SELF-JOIN RAISES. Calling WaitFor from inside the worker's own Run would
     wait forever. EPoolSelfJoin says so instead, because a hang gives you no
     stack, no message, and burns a CI runner until the job times out.

  4. FAULTS ARE CAPTURED, not swallowed. An exception that escapes Execute lands
     in TThread.FatalException, where nothing ever reads it: the thread simply
     "ends" and the work silently disappears. Execute catches it and records the
     class name and message. The bare `else` matters — `on E: Exception` does
     not catch `raise TObject.Create` (measured on both compilers), and letting
     that escape would be a lost failure in a library whose pitch is that it
     does not lose failures.

  5. THE THREAD IS NEVER EXPOSED. No Handle, no Priority, no Suspend, no Resume.
     Re-publishing the footguns this unit exists to remove would undo the point.
}
unit ConcurrentPool.Worker;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils, Classes, SyncObjs{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs{$ENDIF},
  ConcurrentPool.Types,
  ConcurrentPool.Atomic;

type
  { Holds the authority to cancel. The token it hands out can only observe.
    Splitting them means a task physically cannot cancel its siblings. }
  TCancellationSource = class
  strict private
    FEvent: TEvent;
    FFlag: TAtomicCounter;
    FToken: ICancellationToken;
  public
    constructor Create;
    destructor Destroy; override;
    { Idempotent, callable from any thread. Sets the flag before the event, so a
      thread woken by the event always sees the flag already set. }
    procedure Cancel;
    function IsCancelled: Boolean;
    function WaitCancelled(ATimeoutMs: Cardinal): Boolean;
    function Token: ICancellationToken;
  end;

  TWorker = class
  strict private
    FThread: TThread;
    FThreadID: TThreadID;
    FRunnable: IRunnable;
    FSource: TCancellationSource;
    { Guards the two fault STRINGS only. The live state is integers, read
      through the atomic shim without a lock. }
    FLock: TCriticalSection;
    FStateFlag: TAtomicCounter;
    FFaultClassName: string;
    FFaultMessage: string;
    { Manual-reset, set once when the runnable returns. It exists so that a
      bounded WaitFor can BLOCK on something instead of polling the state with a
      Sleep — there is no Sleep anywhere in src/, and TThread.WaitFor offers no
      timeout, so the event is how those two facts coexist. }
    FFinished: TEvent;
    procedure CheckNotSelf;
  private
    { Reached by TWorkerThread, which lives in this unit's implementation
      section. `private` rather than `strict private` for exactly that reason:
      strict private would hide them from another class in the same unit, and
      the alternative — making the thread an inner class — buys nothing. Not
      part of the public surface. }
    procedure SetState(AState: TWorkerState);
    procedure SetFault(const AClassName, AMessage: string);
    procedure ExecuteRunnable;
    procedure SignalFinished;
  public
    constructor Create(const ARunnable: IRunnable);
    destructor Destroy; override;

    { Creates and starts the thread. A second call raises EPoolState. }
    procedure Start;

    { Idempotent, any thread. Cooperative: it sets the token, it does not
      interrupt anything. }
    procedure Cancel;

    { False on timeout. Raises EPoolSelfJoin if called from the worker's own
      thread. }
    function WaitFor(ATimeoutMs: Cardinal): Boolean;

    function State: TWorkerState;
    { An integer flag, so this is safe to read at any time from any thread. }
    function Faulted: Boolean;

    { The thread's id, exposed so a composing type can detect a self-join of its
      own. An id is not a handle: it grants nothing, unlike Handle, Priority,
      Suspend or Resume, which stay hidden. Zero before Start. }
    function ThreadID: TThreadID;

    { Snapshots taken under the lock. Meaningful only after the worker has
      finished — a string field is a pointer plus a refcount, and racing that is
      a double free rather than a stale read, which is why these are documented
      as post-join values and the flag above is not. }
    function FaultClassName: string;
    function FaultMessage: string;
  end;

implementation

type
  { A token is a view onto a source, and holds no authority of its own. }
  TCancellationToken = class(TInterfacedObject, ICancellationToken)
  strict private
    FSource: TCancellationSource;
  public
    constructor Create(ASource: TCancellationSource);
    function IsCancelled: Boolean;
    function WaitCancelled(ATimeoutMs: Cardinal): Boolean;
  end;

  { The only place a TThread is subclassed in this library. }
  TWorkerThread = class(TThread)
  strict private
    FOwner: TWorker;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TWorker);
  end;

{ TCancellationToken }

constructor TCancellationToken.Create(ASource: TCancellationSource);
begin
  inherited Create;
  FSource := ASource;
end;

function TCancellationToken.IsCancelled: Boolean;
begin
  Result := FSource.IsCancelled;
end;

function TCancellationToken.WaitCancelled(ATimeoutMs: Cardinal): Boolean;
begin
  Result := FSource.WaitCancelled(ATimeoutMs);
end;

{ TCancellationSource }

constructor TCancellationSource.Create;
begin
  inherited Create;
  { Manual-reset: cancellation is a latch, so every waiter present and future
    must be released by the single SetEvent. }
  FEvent := TEvent.Create(nil, True, False, '');
  FFlag.Init(0);
  FToken := TCancellationToken.Create(Self);
end;

destructor TCancellationSource.Destroy;
begin
  FToken := nil;
  FEvent.Free;
  inherited Destroy;
end;

procedure TCancellationSource.Cancel;
begin
  { Flag first, then event: a thread released by the event is then guaranteed to
    observe the flag as set. The reverse order would let it wake, poll, see
    False, and park again. }
  FFlag.Exchange(1);
  FEvent.SetEvent;
end;

function TCancellationSource.IsCancelled: Boolean;
begin
  Result := FFlag.Value <> 0;
end;

function TCancellationSource.WaitCancelled(ATimeoutMs: Cardinal): Boolean;
begin
  if FFlag.Value <> 0 then
    Exit(True);
  Result := FEvent.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TCancellationSource.Token: ICancellationToken;
begin
  Result := FToken;
end;

{ TWorkerThread }

constructor TWorkerThread.Create(AOwner: TWorker);
begin
  { Suspended, so the owner can capture the thread id before Execute can run —
    otherwise an immediate WaitFor could race the assignment. }
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TWorkerThread.Execute;
begin
  FOwner.SetState(wsRunning);
  try

  {$IFDEF PROVE_SWALLOW}
  { -------------------------------------------------------------------------
    NEGATIVE BUILD. Not shipped, not reachable from a normal compile.

    Removes the fault capture, so an exception unwinds into the RTL and is
    parked in TThread.FatalException where nothing reads it. The thread just
    "ends" and the work vanishes — which is the entire failure mode this unit
    exists to prevent, and the reason the suite's fault tests must FAIL in this
    build. No timing component: it fails on every run, on any core count, on
    any OS.
    ------------------------------------------------------------------------- }
  FOwner.ExecuteRunnable;
  FOwner.SetState(wsFinished);
  {$ELSE}
  try
    FOwner.ExecuteRunnable;
    FOwner.SetState(wsFinished);
  except
    on E: Exception do
      FOwner.SetFault(E.ClassName, E.Message);
  else
    { `on E: Exception` does not catch a non-Exception raise. Measured on both
      compilers: this branch is what catches `raise TObject.Create`. }
    FOwner.SetFault('(non-Exception)',
      'a non-Exception object was raised and cannot be described further');
  end;
  {$ENDIF}
  finally
    { Signalled on EVERY exit path — normal, faulted, or an escape in the
      PROVE_SWALLOW build — so a bounded WaitFor can never miss it and hang. }
    FOwner.SignalFinished;
  end;
end;

{ TWorker }

constructor TWorker.Create(const ARunnable: IRunnable);
begin
  inherited Create;
  if ARunnable = nil then
    raise EPoolArgument.Create('TWorker requires a runnable.');

  { Init before anything that can raise: a constructor that raises still has its
    destructor called on the half-built object. }
  FStateFlag.Init(Ord(wsCreated));

  FRunnable := ARunnable;
  FSource := TCancellationSource.Create;
  FLock := TCriticalSection.Create;
  FFinished := TEvent.Create(nil, True, False, '');
  { No thread yet. That is the point of hazard 1. }
end;

destructor TWorker.Destroy;
begin
  { Tolerant of every field being nil, because a constructor that raises still
    gets its destructor called. }
  if FSource <> nil then
    FSource.Cancel;

  if FThread <> nil then
  begin
    CheckNotSelf;
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;

  FRunnable := nil;
  FSource.Free;
  FFinished.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TWorker.SetState(AState: TWorkerState);
begin
  FStateFlag.Exchange(Ord(AState));
end;

procedure TWorker.SetFault(const AClassName, AMessage: string);
begin
  FLock.Enter;
  try
    FFaultClassName := AClassName;
    FFaultMessage := AMessage;
  finally
    FLock.Leave;
  end;
  { The state flag is set AFTER the strings, so a reader that sees wsFaulted is
    guaranteed to find both strings already written. The exception object itself
    is never stored: the RTL owns it and destroys it as the handler unwinds, and
    re-raising it on another thread would be a use-after-free. }
  SetState(wsFaulted);
end;

procedure TWorker.ExecuteRunnable;
begin
  FRunnable.Run(FSource.Token);
end;

procedure TWorker.SignalFinished;
begin
  FFinished.SetEvent;
end;

procedure TWorker.CheckNotSelf;
begin
  { TThreadID is 8 bytes on x86_64-linux and 4 on i386-win32 (measured), so it
    is compared as itself and never squeezed into the 32-bit atomic counter. }
  if (FThread <> nil) and (FThreadID = TThread.CurrentThread.ThreadID) then
    raise EPoolSelfJoin.Create(
      'A worker cannot wait for itself. This call came from inside the ' +
      'worker''s own Run.');
end;

procedure TWorker.Start;
begin
  if FThread <> nil then
    raise EPoolState.Create('This worker has already been started.');

  FThread := TWorkerThread.Create(Self);
  try
    { Captured while the thread is still suspended, so a WaitFor issued
      immediately after Start already has a valid id to compare against. }
    FThreadID := FThread.ThreadID;
    FThread.Start;
  except
    { If Start itself fails the thread never runs, so freeing it here is safe
      and leaves the worker in its pre-Start state. }
    FThread.Free;
    FThread := nil;
    raise;
  end;
end;

procedure TWorker.Cancel;
begin
  FSource.Cancel;
end;

function TWorker.WaitFor(ATimeoutMs: Cardinal): Boolean;
begin
  if FThread = nil then
    Exit(True);   { never started: nothing to wait for }

  CheckNotSelf;

  if ATimeoutMs = WAIT_INFINITE then
  begin
    { Waits for the OS thread itself, not just for the runnable to return, which
      is the guarantee Destroy needs before it frees anything the thread reads. }
    FThread.WaitFor;
    Exit(True);
  end;

  { Blocks on the completion event rather than polling the state. TThread.WaitFor
    has no timeout, and an earlier version filled that gap with a Sleep(1) loop —
    which quietly broke this library's own rule that src/ contains no Sleep. The
    event is set on every exit path from Execute, so this cannot miss it.

    Note the semantic: True here means the runnable has returned. The OS thread
    may be a few instructions from ending; only the infinite path above, and
    Destroy, wait for that. }
  Result := FFinished.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TWorker.State: TWorkerState;
begin
  Result := TWorkerState(FStateFlag.Value);
end;

function TWorker.Faulted: Boolean;
begin
  Result := State = wsFaulted;
end;

function TWorker.ThreadID: TThreadID;
begin
  Result := FThreadID;
end;

function TWorker.FaultClassName: string;
begin
  FLock.Enter;
  try
    Result := FFaultClassName;
  finally
    FLock.Leave;
  end;
end;

function TWorker.FaultMessage: string;
begin
  FLock.Enter;
  try
    Result := FFaultMessage;
  finally
    FLock.Leave;
  end;
end;

end.
