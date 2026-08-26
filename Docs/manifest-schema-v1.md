# CardVault transfer manifest schema v1

The authoritative portable record is `.cardvault/transfer-manifest.json`. It is UTF-8 JSON,
pretty-printed with sorted keys. Dates use ISO 8601. Unknown keys may be ignored; a reader must
reject a `schemaVersion` newer than it supports rather than guessing.

Top-level fields record the schema and app versions, transfer UUID and name, dates, durable state,
mode, source identity, destinations, file records, warnings, and errors. Paths in file records are
relative. Mount paths and security-scoped bookmark bytes are deliberately excluded.

Each file records its source and destination relative paths, media classification, size, relevant
timestamps, source SHA-256, and an independent copy/verification result for every destination UUID.
A file is verified only when the SHA-256 calculated by rereading a closed destination file equals
the source SHA-256. The `verifiedAt` date is present only after required verification succeeds.

## Duplicate and conflict classification

A destination result may additionally carry a `conflict` value describing an existing file found at
the destination path: `verifiedByCurrentManifest`, `verifiedByCompatibleManifest`, `contentIdentical`,
`incompletePriorCopy`, `differentContent`, `unrelatedFile`, or `ambiguous`. The field is additive and
absent in manifests written before it existed, so `schemaVersion` remains 1.

A matching filename and byte count never justify a skip. `copyState` becomes `skipped` only after the
destination bytes were reread and hashed, and the resulting digest is stored in `destinationChecksum`
so the decision stays auditable against `sourceChecksum`. `copyState` becomes `conflicted` when
CardVault stopped rather than overwrite content it could not account for; a conflicted file is never
overwritten and never written under an invented filename, and the transfer holds at `needsAttention`
with one `warnings` entry per conflict until the user resolves it.

Only source checksums are compared across manifests, because they do not depend on which tree a copy
landed in. A record from another manifest is consulted only if that manifest's `schemaVersion` is one
this build supports, and it still has to agree with a fresh read of the bytes on disk.

## Relaunch recovery

An unfinished transfer is discovered by its staging directory, named
`.<transfer name>.cardvault-incomplete-<transfer UUID>`, which carries the transfer identity in the
name so a scan can recognise a CardVault artifact before reading anything. The manifest inside is the
only description of what happened; the UI state at the moment of the crash is not durable and is
never guessed at.

The manifest deliberately records no mount paths and no bookmark bytes, so recovery resolves the
source and each destination from security-scoped bookmarks stored per transfer, then confirms each
one against the recorded `VolumeIdentity`. Matching is by volume UUID or partition identifier only: a
card reinserted at a different mount point still matches, and a reformatted card reusing its old
label does not. A stale bookmark is renewed rather than discarded, because a drive that moved is not
a drive that was lost.

`abandonedAt` is set when the user explicitly abandons a transfer. The manifest and every file it
describes stay on disk; the marker only stops recovery from offering the transfer again. It is
additive, so `schemaVersion` remains 1. Abandoning never removes a source file, a verified file, a
file awaiting a conflict decision, or anything CardVault did not write; only artifacts this manifest
recorded as `copying` or `failed` may be removed, and only when the user asks for that explicitly.

A manifest this build cannot decode, and one whose `schemaVersion` is newer than this build supports,
are both reported to the user and never restarted.

Updates are written to a sibling temporary file, then replace the current manifest. The preceding
valid manifest is retained as `transfer-manifest.json.previous` for recovery from a damaged update.
