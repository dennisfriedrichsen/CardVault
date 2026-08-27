# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and test

Two build systems cover the same sources. `Package.swift` maps `Sources/CardVaultCore`, `CardVault/`,
and `CardVaultTests/` onto SwiftPM targets, so the fast loop is SwiftPM and the shippable app is Xcode.

```sh
swift test --disable-sandbox
```

`--disable-sandbox` is required: the tests create and mutate temporary directories.

`--filter` matches Swift type and function names, **not** the display strings in `@Suite`/`@Test` —
filtering on `"Fault injection and interruption reliability"` silently runs zero tests. Use
`SuiteType/functionName`:

```sh
swift test --disable-sandbox --filter "CoreTests/stateMachineValid"
```

Full app build and test through Xcode 26:

```sh
xcodebuild -project CardVault.xcodeproj -scheme CardVault -destination 'platform=macOS' test
```

Two suites are opt-in and skipped by default:

- `VolumeTopologyTests`' real-media suite runs only when `CARDVAULT_DEVICE_VOLUME` names a mounted volume.
- `ProgressBenchmark` is `.serialized` and measures publication overhead; do not run it in parallel with other work.

Swift language mode 6 with complete strict-concurrency checking is on for every target. Deployment
target is macOS 26.

## Product boundary

CardVault ingests, verifies, recovers, records, and safely ejects. It never deletes, renames,
reorganizes, or writes metadata to a source, never erases or formats media, and never says a card is
safe to erase — only that it is safe to eject. Writing metadata to a *destination* copy CardVault
itself created — carrying the source's dates onto it — is on the right side of that line; the source
is still never written to. Browsing, culling, ratings, and analytics belong to SDelight, a separate
app CardVault can optionally hand a verified destination to (`ExternalHandoff.swift`). Reject work
that crosses this line rather than implementing it. `Docs/prompt.txt` is the originating
specification.

## Architecture

`CardVaultCore` (`Sources/CardVaultCore/`) is SwiftUI-independent: actors and value types only. The
SwiftUI layer (`CardVault/`) observes core results and owns no durable truth. `AppModel` is the single
`@MainActor @Observable` bridge; views read it and never talk to core services directly.

Load-bearing pieces and why they exist:

- **`FileSystem.swift`** — every filesystem operation goes through the `LocalFileSystem` actor, which
  embeds `FaultInjector`. Faults are deterministic (byte limits and pass counts, never timing or
  randomness), which is what makes disconnection, short read/write, permission loss, and device-full
  reproducible in temp directories. New I/O must go through this actor or it becomes untestable.
- **`TransferCoordinator.swift`** — reads the source sequentially while keeping primary and backup
  outcomes independent. A verified primary must never mask a failed backup; `TransferOutcome` carries
  per-destination counts for that reason.
- **`TransferLayout.swift`** — the single definition of the on-disk shape
  (`.<name>.cardvault-incomplete-<UUID>/Originals`, `.cardvault/transfer-manifest.json`). Coordinator
  and recovery both derive paths from it; never re-spell the convention elsewhere.
- **`Manifest.swift` / `History.swift` / `HistoryInspection.swift`** — the manifest on the drive is
  authoritative; local history is only an index and is rebuilt from manifests when the two disagree.
- **`Recovery.swift`** — finds unfinished transfers at relaunch. Resume is at whole-file boundaries;
  the only destination file eligible for removal and retry is one the manifest records as in-progress.
- **`VolumeServices.swift` / `VolumeTopology.swift` / `DiskArbitrationAdapter.swift`** — volume identity
  comes from Disk Arbitration behind a mockable provider, falling back to public URL volume metadata.
  An identity resolved via the fallback cannot claim two paths share a physical device. Never identify a
  destination by display name or mount path alone.
- **`Conflicts.swift`** — classifies existing destination content. Existing final or unrelated files are
  never overwritten; a conflict pauses the transfer before verification and waits for a decision.
- **`Timestamps.swift`** — carrying the source's dates onto destination copies. Dates are metadata,
  held to a weaker promise than bytes: applied best effort, recorded per file in the manifest, and
  never allowed to fail a copy whose digest matched. Creation-date support is measured once per
  destination, because a mount that stores none would otherwise report the same fact per file.
- **`ProgressAggregation.swift`** — precise counters live on the coordinator; only throttled snapshots
  reach handlers. Copy and verification progress stay separate so a finished copy can never render as a
  finished transfer.

Every copy is verified independently: source SHA-256 is recorded, the destination copy is closed and
flushed, its size checked, then its SHA-256 recomputed by reading it back.

Sandboxing: the app target uses App Sandbox with user-selected read/write folders. Access outliving a
launch requires an app-scoped security bookmark via `SecurityScopedBookmarkStore`; per-transfer
bookmark keys (`BookmarkKey.source(transferID:)`, `.destination(transferID:destinationID:)`) exist so
recovery can reach a months-old transfer's roots after the last-used selections have moved on.

## Conventions

- Comments explain *why* a rule exists (usually a data-integrity or user-trust reason), not what the
  code does. Match that register; do not add restating comments.
- Unavailable UI actions state their reason. Verification and availability are separate facts: a
  disconnected drive is never presented as unverified.
- Tests use swift-testing (`@Suite`/`@Test`/`#expect`), not XCTest.
- Filesystem semantics differ by format — APFS/HFS+ support the same-volume atomic rename used for
  finalization; exFAT has weaker durability. Compare formats through `VolumeFormat`, never by matching
  `VolumeIdentity.fileSystem` as a string: it holds a Disk Arbitration volume kind (`exfat`, `msdos`)
  when Disk Arbitration resolved it and locale-dependent text (`MS-DOS (FAT32)`) when it did not.
  Finalization never assumes a cross-volume move works.

## Docs

`Docs/` carries the contracts worth reading before changing the matching area:
`manifest-schema-v1.md`, `transfer-history.md`, `fault-injection-coverage.md`,
`progress-performance.md`, and `manual-removable-media-test.md` (the opt-in real-card procedure).

`ui-state-audit.md` is the accessibility and layout audit of the principal UI states, with
`Docs/ui-states/` as its reference screenshots and `ui-state-capture.md` as the one command that
regenerates them. The capture is audit equipment, not a per-change chore: re-run it when actually
auditing the UI, not on every change or PR that happens to touch a view. The screenshots are evidence
for the audit's prose; no test reads them, so a stale row in a picker costs nothing until the next
audit reads it. The states themselves are named in `StatusPresentation.swift` and posed by
`UIStateFixtures.swift`; a new user-visible state belongs in both, or it drops out of the audit.
