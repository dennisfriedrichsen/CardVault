# Initial repository assessment and implementation plan

## Baseline

The initial commit tracked only `LICENSE` and a two-line README describing an iPhone ingest utility.
Empty local directories named `CardVault`, `CardVaultTests`, and `CardVault.xcodeproj` contained no
project file, source, tests, settings, entitlements, assets, or dependencies. There was therefore no
existing functionality, architecture, model, deployment target, Swift version, warning, placeholder,
reusable CardVault code or feature to preserve/refactor/remove. The iPhone description was
removed because the required product is a native macOS utility.

## Requirement comparison

The baseline met none of the V1 implementation criteria beyond having a product name and license.
The clean-room architecture was selected rather than inventing compatibility with an absent design.
The portable JSON manifest—not UI or history—became the authoritative state. The core was separated
from SwiftUI from the first source file.

## Independently testable stages

1. Add macOS 26/Swift 6 project and package configurations with strict concurrency and sandbox entitlements.
2. Add immutable `Sendable` models and validate explicit transfer-state transitions.
3. Add versioned ISO-8601 JSON manifests, safe replacement, previous-valid recovery, and future-schema rejection.
4. Add canonical relative-path scanning, media classification, exclusions, and RAW/JPEG pair counting.
5. Add source/destination topology, capacity, locality, and case-folding preflight checks.
6. Add exclusive file-boundary copy, source/destination SHA-256, flush/close, size checks, and finalization.
7. Add independent dual-destination outcomes and deterministic filesystem fault injection.
8. Add incomplete-transfer discovery and whole-file retry without overwriting verified artifacts.
9. Add native macOS transfer/history UI, mounted-volume discovery, bookmarks, Finder reveal, and ejection.
10. Add reliability tests, schema/build/manual-test documentation, then run Debug tests and a signed Release build.

## Data-integrity decisions

- The source is only opened for reading. No core API can delete, rename, or write a source.
- A destination file is not verified until it is closed, size-checked, reread, SHA-256 hashed, and compared.
- Primary and backup outcomes are never collapsed into one boolean.
- Destination creation is exclusive; conflicts pause/fail instead of overwrite or automatic rename.
- Staging and final locations share a parent so finalization does not become a cross-volume copy.
- Only an artifact durably recorded as `copying` or `failed` may be removed for a whole-file retry.
- Portable manifests contain relative paths and public volume identity, never bookmark bytes or assumed mount paths.
- “Safe to eject” follows handle closure and durable persistence; it never means safe to erase.
