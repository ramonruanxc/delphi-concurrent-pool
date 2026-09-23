{
  ConcurrentPool — a 32-bit interlocked counter.

  This is deliberately a record and not a class, because the two ways a record
  counter goes wrong are exactly what makes the unit worth reading — and both
  are invisible to the compiler. So neither is left as documentation: a guard
  turns both into a deterministic EAssertionFailed on first use, single-threaded,
  before any concurrency is involved.

    1. An uninitialised local. A non-managed record local is not zeroed.
       Measured: FValue read back 22735472 on i386-win32 and -1599891312 on
       x86_64-linux, before a single increment.

    2. A by-value copy. Passing the record to a value parameter silently forks
       the counter — the callee increments its own copy and the caller's value
       never moves.

  The guard catches both with one mechanism: FMagic is zero in a
  zero-initialised class field that was never Init'ed, and garbage in an
  uninitialised local; FOwner stops matching @Self the moment the record is
  copied to a different address.
}
unit ConcurrentPool.Atomic;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils, System.SyncObjs{$ENDIF};

type
  { VALID as a field of a class, a global, or an element of an array — and only
    after Init.

    NOT VALID as a local variable, a value parameter, or a const parameter.
    Never place it in a packed record, or under a PACKRECORDS 1 directive:
    interlocked instructions need the 4-byte field aligned.

    Return-value contract, matching Delphi's TInterlocked so that porting code
    does not silently change meaning:
      Increment, Decrement, Add     -> the value AFTER the operation
      Exchange, CompareExchange     -> the value BEFORE the operation
    Both compilers were measured to agree on the second pair; the first pair
    needs a shim on Free Pascal, where InterLockedExchangeAdd returns the old
    value. }
  TAtomicCounter = record
  strict private
    FValue: LongInt;
    FMagic: LongWord;
    FOwner: Pointer;
    procedure CheckGuard; inline;
  public
    procedure Init(AInitial: LongInt = 0);

    function Increment: LongInt;
    function Decrement: LongInt;
    function Add(ADelta: LongInt): LongInt;

    function Exchange(ANewValue: LongInt): LongInt;
    function CompareExchange(ANewValue, AComparand: LongInt): LongInt;

    { A relaxed snapshot: true at the instant it was read and stale immediately
      afterwards under contention. Correct for reporting and for assertions made
      after a join; never a basis for a decision that must be atomic — use
      CompareExchange for that. }
    function Value: LongInt;
  end;

const
  ATOMIC_MAGIC = LongWord($C0DEBA5E);

implementation

{ Assertions are compiled out unless the build enables them (-Sa on Free Pascal,
  $C+ on Delphi), so the guard costs nothing in a release build and is present
  in every build the test suite uses. }
procedure TAtomicCounter.CheckGuard;
begin
  Assert(FMagic = ATOMIC_MAGIC,
    'TAtomicCounter used without Init - a local, or a field never initialised.');
  Assert(FOwner = @Self,
    'TAtomicCounter was copied by value; the copy and the original are now ' +
    'separate counters. It is valid only as a class field, a global, or an ' +
    'array element.');
end;

procedure TAtomicCounter.Init(AInitial: LongInt);
begin
  FValue := AInitial;
  FMagic := ATOMIC_MAGIC;
  FOwner := @Self;
  { NativeUInt, not FPC's PtrUInt: only NativeUInt exists on both compilers. }
  Assert((NativeUInt(@FValue) mod SizeOf(LongInt)) = 0,
    'TAtomicCounter.FValue is not 4-byte aligned; it must not live in a ' +
    'packed record.');
end;

{$IFDEF PROVE_RACE_ATOMIC}
{ ---------------------------------------------------------------------------
  NEGATIVE BUILD. Not shipped, not reachable from a normal compile.

  Replaces the interlocked read-modify-write with a plain one, so the suite's
  contention test provably loses updates. The read and the write are separated
  by a local and a compiler barrier of sorts so the widened window is real:
  a single instruction (inc [mem]) would still be non-atomic across cores, but
  it loses updates rarely enough that a 2-core CI runner might not observe it,
  and a proof that only sometimes proves is not a proof.
  --------------------------------------------------------------------------- }
function TAtomicCounter.Add(ADelta: LongInt): LongInt;
var
  Snapshot: LongInt;
begin
  CheckGuard;
  Snapshot := FValue;
  Snapshot := Snapshot + ADelta;
  FValue := Snapshot;
  Result := Snapshot;
end;
{$ELSE}
function TAtomicCounter.Add(ADelta: LongInt): LongInt;
begin
  CheckGuard;
  {$IFDEF FPC}
  { Free Pascal's InterLockedExchangeAdd returns the OLD value (measured on
    both targets), so the delta is added back to honour the after-value
    contract. }
  Result := InterLockedExchangeAdd(FValue, ADelta) + ADelta;
  {$ELSE}
  Result := TInterlocked.Add(FValue, ADelta);
  {$ENDIF}
end;
{$ENDIF}

function TAtomicCounter.Increment: LongInt;
begin
  Result := Add(1);
end;

function TAtomicCounter.Decrement: LongInt;
begin
  Result := Add(-1);
end;

function TAtomicCounter.Exchange(ANewValue: LongInt): LongInt;
begin
  CheckGuard;
  {$IFDEF FPC}
  Result := InterLockedExchange(FValue, ANewValue);
  {$ELSE}
  Result := TInterlocked.Exchange(FValue, ANewValue);
  {$ENDIF}
end;

function TAtomicCounter.CompareExchange(ANewValue, AComparand: LongInt): LongInt;
begin
  CheckGuard;
  {$IFDEF FPC}
  Result := InterLockedCompareExchange(FValue, ANewValue, AComparand);
  {$ELSE}
  Result := TInterlocked.CompareExchange(FValue, ANewValue, AComparand);
  {$ENDIF}
end;

function TAtomicCounter.Value: LongInt;
begin
  CheckGuard;
  { A single aligned 32-bit load is atomic on every target this library
    supports, so no interlocked instruction is needed to read it. }
  Result := FValue;
end;

end.
