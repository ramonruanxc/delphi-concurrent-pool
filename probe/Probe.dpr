{
  Throwaway platform probe for delphi-concurrent-pool.

  Every empirical claim behind this library's design was first measured on
  FPC 3.2.2 / i386-win32, but CI runs FPC on x86_64-linux. Codegen, record
  layout, alignment, interlocked availability and pthread event semantics all
  differ across that boundary, and the whole premise of the repo is that the
  tests run where the claims are made. This program re-measures every one of
  them on the CI target before a line of the library is written.

  It lives on a throwaway branch and is deleted once its output is pasted into
  docs/specs. Exit code is 0 even on a surprising result: the point is to READ
  the answers, not to gate on them.
}
program Probe;

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
  {$IFDEF FPC}SysUtils, Classes, SyncObjs, Generics.Collections{$ELSE}
  System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections{$ENDIF};

{ ------------------------------------------------------------------ helpers }

procedure Section(const AName: string);
begin
  WriteLn;
  WriteLn('== ', AName, ' ', StringOfChar('=', 60 - Length(AName)));
end;

procedure Fact(const AName, AValue: string);
begin
  WriteLn('  ', AName: -46, ' ', AValue);
end;

procedure FactB(const AName: string; AValue: Boolean);
begin
  if AValue then Fact(AName, 'YES') else Fact(AName, 'NO');
end;

{ ------------------------------------------------- 1. monotonic clock shim }

procedure ProbeClock;
var
  A, B: UInt64;
  I, Backwards: Integer;
  Prev, Cur: UInt64;
  WrapNow, WrapThen: Cardinal;
begin
  Section('1. GetTickCount64 / monotonic clock');

  A := GetTickCount64;
  Sleep(120);
  B := GetTickCount64;

  Fact('GetTickCount64 compiles', 'YES');
  Fact('first sample', UIntToStr(A));
  Fact('after Sleep(120)', UIntToStr(B));
  Fact('delta (expect >= ~100)', IntToStr(Int64(B - A)));

  { Monotonicity over a tight loop. A wall clock would be allowed to go
    backwards here (NTP, DST); a monotonic one is not. }
  Backwards := 0;
  Prev := GetTickCount64;
  for I := 1 to 200000 do
  begin
    Cur := GetTickCount64;
    if Cur < Prev then
      Inc(Backwards);
    Prev := Cur;
  end;
  Fact('backwards steps over 200k samples', IntToStr(Backwards));

  { Cardinal subtraction is wraparound-safe, which is what Remaining() relies
    on. Computed through variables so the compiler evaluates it at run time
    rather than range-checking a constant expression. }
  WrapNow := Cardinal($00000005);
  WrapThen := Cardinal($FFFFFFFB);
  Fact('wrap arithmetic: $00000005 - $FFFFFFFB',
    UIntToStr(Cardinal(WrapNow - WrapThen)) + ' (expect 10)');
end;

{ ---------------------------------------- 2. manual-reset TEvent semantics }

type
  TWaiter = class(TThread)
  strict private
    FEvent: TEvent;
    FResult: Integer;
    FLabel: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AEvent: TEvent; const ALabel: string);
    property WaitResult: Integer read FResult;
    property Tag: string read FLabel;
  end;

constructor TWaiter.Create(AEvent: TEvent; const ALabel: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FEvent := AEvent;
  FLabel := ALabel;
  FResult := -1;
end;

procedure TWaiter.Execute;
begin
  FResult := Ord(FEvent.WaitFor(5000));
end;

procedure ProbeEvents;
var
  Manual, Auto: TEvent;
  W: array[0..3] of TWaiter;
  Late: TWaiter;
  I, Released: Integer;
begin
  Section('2. TEvent: manual-reset must release ALL waiters, present and future');

  Fact('wrSignaled ordinal', IntToStr(Ord(wrSignaled)));
  Fact('wrTimeout ordinal', IntToStr(Ord(wrTimeout)));

  { The entire Close() design rests on this: a manual-reset event left
    signalled releases every current waiter AND every later arrival. If this is
    false on pthreads, TBoundedQueue.Close cannot wake N parked threads and the
    design changes before implementation. }
  Manual := TEvent.Create(nil, True, False, '');
  try
    for I := 0 to High(W) do
      W[I] := TWaiter.Create(Manual, 'w' + IntToStr(I));
    for I := 0 to High(W) do
      W[I].Start;
    Sleep(200);   { let all four park }

    Manual.SetEvent;   { one call, four waiters }

    for I := 0 to High(W) do
      W[I].WaitFor;

    Released := 0;
    for I := 0 to High(W) do
      if W[I].WaitResult = Ord(wrSignaled) then
        Inc(Released);
    Fact('manual-reset: waiters released by ONE SetEvent',
      IntToStr(Released) + ' of 4');

    for I := 0 to High(W) do
      W[I].Free;

    { A waiter that arrives AFTER SetEvent must also pass, without any further
      signal — the "latched" property Close depends on. }
    Late := TWaiter.Create(Manual, 'late');
    try
      Late.Start;
      Late.WaitFor;
      FactB('manual-reset: LATE arrival passes without a new SetEvent',
        Late.WaitResult = Ord(wrSignaled));
    finally
      Late.Free;
    end;
  finally
    Manual.Free;
  end;

  { Contrast: an auto-reset event is a binary latch — two rapid SetEvents wake
    one waiter, which is precisely why the queue must not use it. }
  Auto := TEvent.Create(nil, False, False, '');
  try
    Auto.SetEvent;
    Auto.SetEvent;
    Fact('auto-reset after TWO SetEvent: first WaitFor(0)',
      IntToStr(Ord(Auto.WaitFor(0))));
    Fact('auto-reset: second WaitFor(0) (expect timeout=1)',
      IntToStr(Ord(Auto.WaitFor(0))));
  finally
    Auto.Free;
  end;
end;

{ ------------------------------------- 3. bare `else` in an except handler }

procedure ProbeNonExceptionRaise;
var
  Caught: string;
begin
  Section('3. except ... else — catching a non-Exception raise');

  { `on E: Exception` does not catch `raise TObject.Create`. TWorker's fault
    capture needs the bare else branch to work, or such a raise escapes Execute
    in a library whose whole pitch is that it does not lose failures. }
  Caught := '(nothing)';
  try
    try
      raise TObject.Create;
    except
      on E: Exception do
        Caught := 'on E: Exception -> ' + E.ClassName;
    else
      Caught := 'bare else branch';
    end;
  except
    on E: Exception do
      Caught := 'ESCAPED as ' + E.ClassName;
  end;
  Fact('raise TObject.Create was caught by', Caught);
end;

{ ----------------------------------- 4. assertions, incl. in record methods }

type
  TGuardedCounter = record
  strict private
    FValue: LongInt;
    FMagic: LongWord;
    FOwner: Pointer;
  public
    procedure Init;
    function Increment: LongInt;
    function Raw: LongInt;
  end;

const
  GuardMagic = LongWord($C0DEBA5E);

procedure TGuardedCounter.Init;
begin
  FValue := 0;
  FMagic := GuardMagic;
  FOwner := @Self;
end;

function TGuardedCounter.Increment: LongInt;
begin
  { The guard from the design: catches an uninitialised record AND a by-value
    copy, because a copy moves and @Self no longer matches. }
  Assert((FMagic = GuardMagic) and (FOwner = @Self),
    'TGuardedCounter used uninitialised or copied by value');
  Result := InterLockedExchangeAdd(FValue, 1) + 1;
end;

function TGuardedCounter.Raw: LongInt;
begin
  Result := FValue;
end;

procedure BumpByValue(ACounter: TGuardedCounter);
begin
  try
    ACounter.Increment;
    Fact('by-value copy: guard did NOT fire', 'PROBLEM');
  except
    on E: Exception do
      Fact('by-value copy: guard fired as', E.ClassName);
  end;
end;

procedure ProbeAssertions;
var
  Good: TGuardedCounter;
  Uninit: TGuardedCounter;
  I: Integer;
begin
  Section('4. Assertions (-Sa) and the record guard');

  {$IFOPT C+}
  Fact('assertions compiled in ($C+ / -Sa)', 'YES');
  {$ELSE}
  Fact('assertions compiled in ($C+ / -Sa)', 'NO — build with -Sa');
  {$ENDIF}

  Good.Init;
  for I := 1 to 5 do
    Good.Increment;
  Fact('initialised record: 5 increments ->', IntToStr(Good.Raw));

  { An uninitialised LOCAL of a non-managed record is not zeroed. Print the
    garbage so the README can state it as a measured fact on this platform. }
  Fact('uninitialised local FValue reads back', IntToStr(Uninit.Raw));
  try
    Uninit.Increment;
    Fact('uninitialised local: guard did NOT fire', 'PROBLEM');
  except
    on E: Exception do
      Fact('uninitialised local: guard fired as', E.ClassName);
  end;

  BumpByValue(Good);
  Fact('original after by-value attempt (expect 5)', IntToStr(Good.Raw));

  Fact('SizeOf(TGuardedCounter)', IntToStr(SizeOf(TGuardedCounter)));
  Fact('alignment of FValue within record',
    'record addr mod 4 = ' + IntToStr(PtrUInt(@Good) mod 4));
end;

{ --------------------- 5. generic class with sync-object fields on this ABI }

type
  TSyncBox<T> = class
  strict private
    FLock: TCriticalSection;
    FGate: TEvent;
    FRing: array of T;
    FEmpty: T;
    FCount: Integer;
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;
    function Push(const AItem: T): Boolean;
    function Pop(out AItem: T): Boolean;
    function Count: Integer;
  end;

constructor TSyncBox<T>.Create(ACapacity: Integer);
begin
  inherited Create;
  SetLength(FRing, ACapacity);
  FLock := TCriticalSection.Create;
  FGate := TEvent.Create(nil, True, False, '');
end;

destructor TSyncBox<T>.Destroy;
begin
  FGate.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSyncBox<T>.Push(const AItem: T): Boolean;
begin
  FLock.Enter;
  try
    if FCount >= Length(FRing) then
      Exit(False);
    FRing[FCount] := AItem;
    Inc(FCount);
    Result := True;
    FGate.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TSyncBox<T>.Pop(out AItem: T): Boolean;
begin
  AItem := FEmpty;
  FLock.Enter;
  try
    if FCount = 0 then
      Exit(False);
    Dec(FCount);
    AItem := FRing[FCount];
    { Clearing the vacated slot is the behaviour TQueue<T> does NOT have. }
    FRing[FCount] := FEmpty;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TSyncBox<T>.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FCount;
  finally
    FLock.Leave;
  end;
end;

procedure ProbeGenerics;
var
  Box: TSyncBox<Integer>;
  V: Integer;
begin
  Section('5. Generic class holding TCriticalSection + TEvent + array of T');

  Box := TSyncBox<Integer>.Create(4);
  try
    Fact('push 10/20', BoolToStr(Box.Push(10), True) + '/' +
      BoolToStr(Box.Push(20), True));
    Fact('count', IntToStr(Box.Count));
    Box.Pop(V);
    Fact('pop ->', IntToStr(V));
    Fact('count after pop', IntToStr(Box.Count));
  finally
    Box.Free;
  end;
  Fact('generic class with sync fields on this target', 'COMPILES AND RUNS');
end;

{ ------------------------------- 6. TQueue<T> vacated-slot reference leak }

type
  TTracked = class(TInterfacedObject)
  public
    destructor Destroy; override;
  end;

var
  GDestroyed: LongInt = 0;

destructor TTracked.Destroy;
begin
  InterLockedIncrement(GDestroyed);
  inherited Destroy;
end;

procedure ProbeQueueSlotLeak;
var
  Q: TQueue<IInterface>;
  I: Integer;
  Item: IInterface;
begin
  Section('6. TQueue<T>: does Dequeue release the vacated slot?');

  { The design rejected TQueue<T> as the ring storage because a dequeued
    interface appeared to stay alive in the vacated slot. Re-measure here so the
    README can name the platform alongside the claim. }
  GDestroyed := 0;
  Q := TQueue<IInterface>.Create;
  try
    for I := 1 to 100 do
    begin
      Q.Enqueue(TTracked.Create);
      Item := Q.Dequeue;
      Item := nil;
    end;
    Fact('100 x enqueue/dequeue, destroyed before Free', IntToStr(GDestroyed));
  finally
    Q.Free;
  end;
  Fact('destroyed after Q.Free', IntToStr(GDestroyed) + ' of 100');

  GDestroyed := 0;
  Q := TQueue<IInterface>.Create;
  try
    Q.Enqueue(TTracked.Create);
    Item := Q.Dequeue;
    Item := nil;
    Fact('single item: destroyed before Free', IntToStr(GDestroyed));
  finally
    Q.Free;
  end;
  Fact('single item: destroyed after Free', IntToStr(GDestroyed) + ' of 1');
end;

{ ------------------------------------------- 7. interlocked surface, 64-bit }

procedure ProbeInterlocked;
var
  N: LongInt;
  Old: LongInt;
begin
  Section('7. Interlocked surface on this target');

  N := 0;
  Fact('InterLockedIncrement returns', IntToStr(InterLockedIncrement(N)));
  Fact('value now', IntToStr(N));
  Fact('InterLockedDecrement returns', IntToStr(InterLockedDecrement(N)));
  Old := InterLockedExchangeAdd(N, 5);
  Fact('InterLockedExchangeAdd(+5) returned OLD', IntToStr(Old));
  Fact('value now (expect 5)', IntToStr(N));
  Old := InterLockedExchange(N, 42);
  Fact('InterLockedExchange(42) returned OLD', IntToStr(Old));
  Fact('value now (expect 42)', IntToStr(N));
  Old := InterLockedCompareExchange(N, 99, 42);
  Fact('InterLockedCompareExchange(99,42) returned OLD', IntToStr(Old));
  Fact('value now (expect 99)', IntToStr(N));

  Fact('SizeOf(LongInt)', IntToStr(SizeOf(LongInt)));
  Fact('SizeOf(Pointer)', IntToStr(SizeOf(Pointer)));
  Fact('SizeOf(TThreadID)', IntToStr(SizeOf(TThreadID)));
end;

{ --------------------------------------------------------------------- main }

begin
  WriteLn('delphi-concurrent-pool — platform probe');
  {$IFDEF FPC}
  WriteLn('compiler : Free Pascal ', {$I %FPCVERSION%});
  WriteLn('target   : ', {$I %FPCTARGETCPU%}, '-', {$I %FPCTARGETOS%});
  {$ELSE}
  WriteLn('compiler : Delphi');
  {$ENDIF}

  ProbeClock;
  ProbeEvents;
  ProbeNonExceptionRaise;
  ProbeAssertions;
  ProbeGenerics;
  ProbeQueueSlotLeak;
  ProbeInterlocked;

  WriteLn;
  WriteLn('probe complete');
end.
