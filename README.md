# CardVault

CardVault is a native macOS 26+ ingest utility for safely transferring photographs and videos from
SD cards to the Mac or directly attached drives.

> CardVault will not say your photographs are safe until every transferred file has been verified.

## Product boundary

CardVault scans a source without modifying it, copies to a primary and optional backup destination,
rereads every destination file, verifies SHA-256, records portable manifests and local history, and
supports safe ejection. It never deletes, renames, reorganizes, or writes metadata to a source. It
never erases/formats media and never claims that a card is safe to erase.

Photo browsing, culling, ratings, histograms, pixel inspection, comparison, and analytics are outside
CardVault's product boundary. A verified destination can be revealed in Finder.

## Architecture

- `CardVaultCore` is a SwiftUI-independent Swift 6 actor/value-type library. It owns scanning,
  UTType-assisted media classification, preflight, volume identity, bookmarks, state transitions,
  exclusive copying, SHA-256 verification, manifest replacement, recovery discovery, and history.
- `TransferCoordinator` reads sources predictably and sequentially, while keeping primary and backup
  outcomes independent. Filesystem operations run behind an actor with deterministic fault injection.
- `CardVault` is the macOS SwiftUI presentation layer. The navigation split view, Mac toolbar,
  keyboard commands, folder panels, phased progress, history table with double-click manifest reveal,
  Finder reveal, and eject action observe core results without owning durable truth.
- `.cardvault/transfer-manifest.json` is the authoritative portable record. The local history is only
  an index. See [manifest schema v1](Docs/manifest-schema-v1.md).

Strict concurrency checking is enabled. The app target uses App Sandbox with user-selected read/write
folders and app-scoped security bookmarks. The core and tests do not require a physical SD card.
The detected-volumes menu updates as removable volumes are mounted or unmounted. Choosing a detected
removable volume opens a macOS permission panel rooted at that volume; access is
saved for later launches with a security-scoped bookmark.

## Transfer behavior

Preserve Card (default) retains the complete structure. Media Only copies recognized RAW, JPEG,
HEIF/HEIC, TIFF, PNG, camera video, and XMP sidecars while preserving relative folders and disclosing
exclusions. Custom Destination copies into the chosen folder without a proprietary library.

New transfers use `.<name>.cardvault-incomplete-<UUID>/Originals` until completion. Existing final or
unrelated files are not overwritten. Source SHA-256 is recorded, every destination copy is closed and
flushed, its size is checked, then its SHA-256 is independently computed. A successful primary never
hides an incomplete backup. Resume is at file boundaries; an artifact recorded as in-progress is the
only destination file eligible for removal and retry.

“Safe to eject” means CardVault has closed source handles and persisted recovery state. It does not mean
safe to erase.

## Filesystem notes

- APFS and HFS+ support same-volume atomic directory renames used for finalization.
- exFAT is supported for ordinary camera media, but has weaker metadata/durability semantics and naming
  limits. Preflight blocks case-folding collisions and reports capacity/local-volume limitations.
- Destination identity uses public volume UUID/resource metadata when available, not display names or
  mount paths alone. Two folders on one physical-volume identity produce a non-independence warning.
- The primary destination must be local. An optional network/NFS backup is supported and must remain
  mounted through copy and verification. Capacity detection falls back to filesystem statistics when
  a network volume does not report macOS's preferred capacity value. Finalization never assumes
  cross-volume moves.

## Build and test

Open `CardVault.xcodeproj` in Xcode 26. The deployment target is macOS 26, Swift language mode is 6,
and complete strict-concurrency checking is enabled.

```sh
xcodebuild -project CardVault.xcodeproj -scheme CardVault \
  -destination 'platform=macOS' build

xcodebuild -project CardVault.xcodeproj -scheme CardVault \
  -destination 'platform=macOS' test
```

The Swift package provides a lightweight core/test workflow:

```sh
swift test --disable-sandbox
```

See the [manual removable-media procedure](Docs/manual-removable-media-test.md) for opt-in testing with
a real card, APFS/HFS+/exFAT destinations, disconnections, sleep, exhausted space, and safe ejection.

## Current limitations

V1 resumes at whole-file boundaries, not partial-file offsets. Disk identity is based on public URL
volume metadata; a dedicated Disk Arbitration adapter can improve whole-device topology on complex disk
layouts. Automatic performance profiling and destructive real-media fault tests remain manual. Cloud,
catalog import, source deletion, formatting, privileged helpers, and proprietary libraries are outside
the product boundary.
