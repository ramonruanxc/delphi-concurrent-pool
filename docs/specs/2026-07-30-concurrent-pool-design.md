# delphi-concurrent-pool — design

Date: 2026-07-30
Status: design frozen; platform claims measured on the CI target; implementation next.

## What it is

Three primitives and the pool that composes them: a bounded blocking queue, a
worker that owns its thread, and a fixed-size pool that drains the queue.

It is the second half of a pair. [delphi-concurrent-log](https://github.com/ramonruanxc/delphi-concurrent-log)
ends its README with:

> The cost is that sinks run serially while the lock is held, so a slow sink
> slows every logging thread. If you need to log across a slow sink without
> blocking callers, put a queue in front of it — a sink that hands entries to a
> background writer thread. That is a natural extension and intentionally left
> out of the core.

This repo is that extension, and the primary demo is exactly that async sink.

## Why not System.Threading / TThreadedQueue

Answered up front because it is the first question a reviewer should ask.

`System.Threading` (TTask, TParallel) and `TThreadedQueue<T>` are Delphi-only.
Neither exists in Free Pascal, and Free Pascal is what makes it possible to run
a concurrency test suite in CI at all: Delphi cannot be licensed on a hosted
runner, and its Community Edition refuses command-line compilation even
locally. A library built on the RTL's threading types could only ever be tested
by hand, on one machine, by its author — which for a library about races is not
testing.

So the constraint came first and the design followed: primitives built on
`TThread`, `TCriticalSection`, `TEvent` and the interlocked intrinsics, all of
which exist on both compilers, and a suite that runs on every push.

If you are Delphi-only and want a task API, use `System.Threading`. This is for
code that has to build on both, or that wants its concurrency claims tested.

## Platform facts, measured

Every claim below was produced by `probe/Probe.dpr` on both targets. The
i386-win32 column is a developer machine; the x86_64-linux column is the CI
runner. Re-measuring on the CI target was not ceremony — it corrected the
design twice (see "Corrections" below).

| Fact | i386-win32 | x86_64-linux |
| --- | --- | --- |
| `GetTickCount64` exists, monotonic (200k samples) | yes, 0 backwards | yes, 0 backwards |
| `Cardinal` subtraction wraps safely | 10 | 10 |
| manual-reset `TEvent`: one `SetEvent` releases 4 parked waiters | 4 of 4 | 4 of 4 |
| manual-reset `TEvent`: a waiter arriving *after* `SetEvent` passes | yes | yes |
| auto-reset `TEvent`: two `SetEvent` then two `WaitFor(0)` | signalled, then timeout | signalled, then timeout |
| `except ... else` catches `raise TObject.Create` | yes | yes |
| assertions active under `-Sa` | yes | yes |
| uninitialised local record field reads garbage | 22735472 | -1599891312 |
| record guard fires on uninitialised use | `EAssertionFailed` | `EAssertionFailed` |
| record guard fires on by-value copy | `EAssertionFailed` | `EAssertionFailed` |
| generic class with `TCriticalSection` + `TEvent` + `array of T` | runs | runs |
| `InterLockedIncrement` / `Decrement` return | NEW value | NEW value |
| `InterLockedExchangeAdd` / `Exchange` / `CompareExchange` return | OLD value | OLD value |
| `SizeOf(LongInt)` | 4 | 4 |
| `SizeOf(Pointer)` | 4 | 8 |
| `SizeOf(TThreadID)` | 4 | **8** |
| `SizeOf` of the guarded counter record | 12 | 16 |
| heaptrc on a deliberate leak | — | `1 unfreed memory blocks : 8`, **exit code 0** |
| CI runner cores (`nproc`) | — | **2** |

### Corrections the probe forced

**1. `TQueue<T>` does not leak dequeued interface references.** The design
review asserted that FPC 3.2's `TQueue<T>.Dequeue` leaves the vacated slot
holding a reference, citing "100 rounds destroyed 99/100" and a single-item case
destroying 0. Measured directly with `TQueue<IInterface>` over
`TInterfacedObject`: **100 of 100 destroyed before `Free`, and 1 of 1 in the
single-item case, on both targets.** The claim is withdrawn and must not appear
in the README.

The ring buffer stays, for the reason that survives: in a library whose selling
point is a *bounded* queue, the bound belongs in the storage rather than in a
counter beside it, and clearing the vacated slot is then visible in the code
instead of being a property of somebody else's container.

**2. `TThreadID` is 8 bytes on x86_64-linux and 4 on i386-win32.** The
self-join check therefore compares `TThreadID` values directly and must never
be stashed in the 32-bit interlocked counter — that would truncate the id on
the CI target and make self-join detection fail exactly where the tests run.

**3. The heaptrc gate has to be anchored.** A leak produced
`1 unfreed memory blocks : 8` while the **process still exited 0**, so grepping
is mandatory rather than stylistic. And the pattern must be anchored — an
unanchored `0 unfreed memory blocks` also matches `10 unfreed memory blocks`.
The gate is `grep -qE '^0 unfreed memory blocks'`.

**4. The runner has 2 cores.** The lost-update proof is the one statistical
proof in the repo, and 2 cores is thin. It widens the race window deliberately,
uses a start gate so all threads hammer at once, and CI retries it up to three
times before failing. The README says this out loud and does not lead with it —
the deterministic proofs come first.

## Units

Dependency order is a line with no back-edges:

```
Types -> Atomic -> Queue -> Worker -> Pool
```

- **`ConcurrentPool.Types`** — shared vocabulary. `TQueueWait = (qwOK,
  qwTimeout, qwClosed)`: three outcomes because two cannot be acted on —
  `qwTimeout` means "try again", `qwClosed` means "stop forever", and a Boolean
  makes the pool unimplementable. `ICancellationToken` with both `IsCancelled`
  and `WaitCancelled`, because a poll-only token cannot unblock a parked
  runnable. `IRunnable`, and a `TMethodRunnable` adapter so a one-line task does
  not cost a class. A monotonic clock shim (`Ticks`, `Elapsed`, `Remaining`)
  whose subtraction stays in `Cardinal`.

- **`ConcurrentPool.Atomic`** — `TAtomicCounter`, a record with a guard
  (`FMagic` + `FOwner = @Self`) that turns its two compiler-invisible hazards —
  an uninitialised local, and a by-value copy that silently forks the counter —
  into a deterministic `EAssertionFailed` on first use. Measured: both fire.

- **`ConcurrentPool.Queue`** — `TBoundedQueue<T>`, a ring with **two
  manual-reset events whose signalled state mirrors the predicate**, maintained
  only under the lock, and a latched `Close`. Manual-reset is not a style
  choice: an auto-reset event is a binary latch, so it cannot release the N
  waiters `Close` has to release, and it loses wakeups when two pushes land in
  quick succession. Both properties were measured above.

- **`ConcurrentPool.Worker`** — owns a `TThread` it never exposes. No thread
  until `Start`. `Destroy` joins unconditionally. Self-join raises instead of
  hanging. Faults are captured inside `Execute` as class name and message
  strings, including via a bare `else` for a non-`Exception` raise.

- **`ConcurrentPool.Pool`** — `TWorkerPool`, visibly a composition of the other
  three. Two named shutdowns rather than a Boolean parameter, `WaitIdle`, and
  the accounting invariant `Submitted = Completed + Faulted + Dropped` asserted
  at the end of every pool test.

## Structural rules

1. **Locks are leaf-level.** No component calls user code, another component,
   or an allocation-heavy operation while holding a lock. That is why
   `Item.Run` is invoked with nothing held, why submitting from inside a running
   task works, and why there is no lock order in the library to invert.
2. **Every public method takes its lock exactly once** and does its work
   through non-locking strict-private helpers. Re-entrancy is never relied on,
   which is why it does not matter whether FPC's `TCriticalSection` is a
   recursive mutex on Linux — a `Count` that locked, called from inside a
   `Push` that already held the lock, would work on Windows and deadlock on
   Linux, the worst possible split.
3. **No `Sleep` in `src/`.** Waiting is on events whose state mirrors a
   predicate.
4. **Every wait in `tests/` is bounded.** A hazard in this library fails by
   blocking, so the ability to turn a hang into a named assertion failure is a
   functional requirement of the proof strategy, not CI polish.

## Negative builds

Each removes exactly one safety property and is required to **fail by
assertion, never by hanging**. Each gets its own `-FU` directory, because FPC
does not treat a changed `-d` define as a reason to recompile.

| Build | Removes | Fails | Kind |
| --- | --- | --- | --- |
| `PROVE_SWALLOW` | the `try/except` in the worker's `Execute` | fault tests | deterministic — leads the README |
| `PROVE_NOWAKE` | the `SetEvent`s in `Close` | blocked producers/consumers time out instead of returning `qwClosed` | deterministic |
| `PROVE_RACE_QUEUE` | the lock around the ring indices | integer instantiation loses or duplicates values | deterministic enough |
| `PROVE_RACE_ATOMIC` | the interlocked mutators | lost updates | statistical; 2-core runner, retried 3× |

## Out of scope

- **Futures/results per task.** `IRunnable` returns nothing. A result type wants
  cancellation propagation, continuations and exception marshalling, and that is
  a different library.
- **Work stealing, dynamic pool sizing, priorities.** Fixed size, one shared
  queue. Anything else needs a benchmark to justify it, and there is none here.
- **`TMonitor`, `TInterlocked`, anonymous methods.** Delphi-only; measured
  absent on FPC 3.2. Callbacks are interfaces or `of object`, deliberately.
- **Thread affinity, priority, suspend/resume.** `TWorker` never exposes its
  thread. Re-publishing those footguns would undo the point.
