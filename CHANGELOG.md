# Changelog

This project follows [Semantic Versioning](https://semver.org/).

## [1.0.0] — unreleased

First release. A bounded queue, a worker and a pool, extracted from a personal
systems project and rebuilt as a standalone, tested component — the second half
of a pair with [delphi-concurrent-log](https://github.com/ramonruanxc/delphi-concurrent-log),
whose README named this as the extension it deliberately left out.

### Added

- `TAtomicCounter`: a 32-bit interlocked counter with a guard that turns its two
  compiler-invisible hazards — an uninitialised local and a by-value copy —
  into a deterministic `EAssertionFailed` on first use. Return values match
  Delphi's `TInterlocked`: `Increment`/`Decrement`/`Add` give the value after,
  `Exchange`/`CompareExchange` the value before.
- `TBoundedQueue<T>`: a ring with two manual-reset events whose signalled state
  mirrors the predicate, a latched `Close` that releases every parked producer
  and consumer, one deadline per call rather than a fresh timeout per wake, and
  `DrainAndClose` for accounted abandonment. `TQueueWait` distinguishes
  `qwTimeout` from `qwClosed`, because a Boolean makes the pool
  unimplementable.
- `TWorker`: owns a `TThread` it never exposes. No thread until `Start`,
  `Destroy` joins unconditionally, self-join raises `EPoolSelfJoin` rather than
  hanging, and faults are captured as class name and message — including a
  non-`Exception` raise, via a bare `else`.
- `ICancellationToken` with `WaitCancelled` as well as `IsCancelled`, so a task
  parked in a wait can be released. A poll-only token would make
  cancel-then-join a guaranteed deadlock.
- `TWorkerPool`: fixed workers over one shared queue, `Shutdown` and
  `ShutdownNow` as separate named methods, `WaitIdle`, and the invariant
  `Submitted = Completed + Faulted + Dropped` asserted at the end of every pool
  test.
- 96 assertions, run in CI on every push, with the deterministic tests first and
  the one statistical test labelled as such.
- Four negative builds — `PROVE_SWALLOW`, `PROVE_NOWAKE`, `PROVE_RACE_QUEUE`,
  `PROVE_RACE_ATOMIC` — each removing one safety property. CI fails if the suite
  still passes without it.
- A watchdog that halts with the offending test's name, so a deadlock produces a
  bug report rather than a dead runner. CI verifies the watchdog itself with
  `--watchdog=0`.
- A leak gate over heaptrc output, grepped with an anchored pattern because a
  leak leaves the exit code at 0 and `0 unfreed` otherwise matches `10 unfreed`.
- Two demos: `AsyncSink` (a slow sink behind a queue, back-pressure against
  dropping, side by side) and `Pipeline` (fault isolation, and cancelling a task
  that is parked rather than polling).
- `boss.json` for installation through Boss.

### Notes on portability

Everything is built from `TThread`, `TCriticalSection`, `TEvent` and the
interlocked intrinsics, all of which exist on both compilers.
`System.Threading`, `TThreadedQueue`, `TMonitor` and anonymous methods are
Delphi-only and are avoided; `TInterlocked` is used on Delphi behind a shim.

Design decisions and the platform measurements behind them are recorded in
`docs/specs/2026-07-30-concurrent-pool-design.md`, including the six corrections
that a probe run on the CI target forced on the original plan.
