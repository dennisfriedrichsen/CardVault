# Progress reporting, transfer rate, and estimated time

CardVault publishes performance information without letting a fast drive drive
SwiftUI invalidation. This document records the design, the chosen thresholds,
the measurements behind them, and the measurements that still require hardware.

## Where the numbers come from

`LocalFileSystem` reports every chunk it reads or writes through an optional
`ByteHandler`. Those reports go to the `TransferCoordinator` actor, which owns a
`ProgressAggregator` for the phase in flight. The aggregator keeps the precise
counters and releases a `TransferProgress` snapshot only when a threshold is
crossed. Nothing reaches the main actor between snapshots, so chunk frequency and
UI invalidation frequency are decoupled.

Copy and verification each get their own aggregator. They never share counters,
rate samples, or throttling state, and `AppModel` stores them in separate
properties so a verification update does not invalidate the copy view.

### Work bytes

`completedBytes` and `totalBytes` count *work* bytes rather than payload bytes.
A file that is hashed at the source and written to two destinations contributes
its size three times to the copy phase, and twice to the verification phase. The
bar, the rate, and the estimate therefore all describe the same quantity, and a
resumed transfer credits skipped work so the bar still reaches 100 percent.

### Rate and estimate

The rate is the slope across a sliding window of samples: committed samples are
spaced at least `rateSampleInterval` apart to bound memory, and the most recent
observation is always included so the estimate stays current between them. A
window shorter than one sampling interval reports no rate at all — a single
fast chunk read from cache would otherwise be published as tens of gigabytes per
second. The estimate is simply the remaining work bytes divided by that rate.

Both values are estimates and are labelled as such in the UI ("Estimated ·
420 MB/s · 2 min remaining"). Neither is used for any correctness decision.

## Chosen thresholds

| Knob | Value | Why |
| --- | --- | --- |
| `progressInterval` | 0.2 s | Hard cap of five UI snapshots per second. Fast enough to read as live motion, slow enough that SwiftUI invalidation is not measurable against I/O. |
| `rateWindow` | 5 s | Long enough to absorb per-file boundaries and manifest writes; short enough that a card slowing down shows up within a few seconds. |
| `rateSampleInterval` | 0.1 s | Bounds retained samples to about 50 per phase, and sets the shortest window a rate may be computed from. |
| `chunkBytes` | 1 MiB | Unchanged from V1. Large enough to keep syscall overhead irrelevant on SD cards, small enough to keep cancellation responsive at chunk granularity. |
| `destinationConcurrency` | 1 | Sequential by default. See below. |

All five live in `TransferTuning`, are injected into `TransferCoordinator`, and
are internal tuning values rather than user-facing settings.

### Why the byte-count trigger was removed

An earlier revision also released a snapshot every 8 MiB, on the theory that a
fast drive should report more often. Measured on this machine's internal SSD it
did the opposite of what was wanted: at roughly 2.4 GB/s of work bytes it
produced **250 snapshots per second**, one main-actor hop each. Making
`progressInterval` the only trigger dropped the same transfer to **9 snapshots
total** (about 10 per second, boundaries included) with no visible loss of
fidelity. Time is now the only trigger, which also makes the cap trivially
testable.

## Measurements

Reproduce with:

```bash
swift test -Xswiftc -DCARDVAULT_BENCHMARK --filter ProgressBenchmark
```

512 MiB across 16 files, Apple silicon internal SSD, Debug build. Both
destinations were directories on that same SSD.

| Run | Elapsed | Snapshots | Snapshots/s | Peak reported rate |
| --- | --- | --- | --- | --- |
| Single destination | 0.91 s | 9 | 9.9 | 2290 MB/s |
| Dual, `destinationConcurrency: 1` | 1.34–1.83 s | 12–14 | 7.7–8.9 | 2281 MB/s |
| Dual, `destinationConcurrency: 2` | 1.24–1.46 s | 12–13 | 8.9–9.7 | 2341 MB/s |

Bounded-concurrency verification is 7–20 percent faster here, but both
destinations shared one physical device, which is the case concurrency helps
least. That is why the default stays at 1: the gain is small, and overlapping
reads on one device is the shape most likely to hurt removable media.

### Still to measure on hardware

These require the physical devices and are not yet recorded:

- SwiftUI view invalidation counts from Instruments' SwiftUI instrument
  (`View Body` / `View Properties`), copy phase and verification phase, before
  and after this change.
- Sequential versus `destinationConcurrency: 2` on a representative SD card
  reader plus two *separate* external drives.
- Copy throughput from a card reader to a local primary plus an NFS or SMB
  backup, before and after the single-read copy described above.
- Rate and estimate stability on a UHS-I card, where per-file overhead is a much
  larger share of elapsed time than on the SSD above.

Record results in this table when the runs happen; change
`TransferTuning.default` only alongside a row here that justifies it.

## Work per file in the copy phase

Each file used to be read from the card once to hash it and then once more for
every destination, and the manifest was saved to every destination before and
after each destination's copy. With a network backup, that made the server's
round trips, not the card, set the pace: one real transfer to an NFS share over
Wi-Fi spent as many RPCs on manifest creates, renames, locks and commits as on
photo data, and the card sat mostly idle.

The copy now reads each file once and writes every chunk to all destinations
before reading the next chunk. Like the hashing pass, that read computes a
digest, and a file whose second read disagrees with the first is failed at
every destination as `sourceChanged` instead of being caught later as a
verification mismatch. The hashing pass
itself stays separate, so the recorded source digest still comes from a read
independent of the one that produced the copies.

Each destination's failure is still its own: a destination that stops is closed,
its partial file removed, and its error recorded, while the others finish the
same file from the same read. Every copy is still flushed, sized, and read back
for verification.

Per file, with two destinations:

| | Before | After |
| --- | --- | --- |
| Reads of the source | 3 | 2 |
| Manifest saves, copy phase | 8 | 4 |
| Manifest saves, verification | 4 | 2 |
| Temporary files per manifest save | 2 | 1 |

Before any byte of a file is written, every copy about to start is recorded as
`copying` in one save, so recovery's rule — only a file the manifest records as
in progress may be removed and retried — holds for every destination at once. A
verification result lost between two saves is only a copy read back again on
resume. `FaultInjectionTests` pins both counts (`sourceReadsPerFile`,
`manifestSavesPerFile`).

`ProgressBenchmark` before and after, three runs each on this machine's SSD:
snapshot rates are unchanged (5–11 per second), and elapsed times overlap
within run-to-run noise (dual-destination: 1.5–3.9 s before, 1.9–3.1 s after).
Both destinations of the benchmark sit on the same fast flash, which is the case
this change helps least; a measurement on a real card reader with a network
backup belongs under "Still to measure on hardware".

## What did not change

Copy at 100 percent is a phase boundary, never a result. `TransferProgress`
exposes `isPhaseComplete` for the phase only, the copy card says "Copy complete —
verification still in progress", and the only success indicator in the UI reads
from `TransferOutcome`. Checksums, flush and close ordering, the
existing-conflict rules, and whole-file resume are untouched: verification still
computes one SHA-256 per destination copy and compares it to the source digest,
and manifest updates are still applied in destination order even when the
hashing that produced them ran concurrently; they are persisted once per file.
