# Transfer history, manifest authority, and destination availability

CardVault's history is an index, not a catalog. It exists so a past transfer can be *audited* —
what was copied, from which card, to which drives, and what each drive independently verified —
without CardVault becoming the thing the photographs depend on. Every fact it shows is recoverable
from the drives themselves.

## The manifest is authoritative

`.cardvault/transfer-manifest.json` inside each transfer folder is the record. The local index at
`~/Library/Application Support/CardVault/transfer-history.json` is a convenience copy that makes the
list fast to open and readable when no drive is connected.

When the two disagree, the detail view says so, names the manifest as authoritative, and shows the
differing fields side by side. Nothing is silently reconciled in the index's favour.

| Situation | What is shown |
|---|---|
| Manifest readable and agrees | The detail, with no banner |
| Manifest readable and disagrees | A banner naming the manifest as authoritative, plus a field-by-field table |
| No destination connected | A banner saying the index is only an index and the manifest could not be consulted |
| Manifest newer than this build | The schema version, and the destination still openable for inspection |

At launch, manifests found on connected destination roots rebuild index entries and replace what the
index holds. A deleted or corrupted index therefore costs a rescan, not a record.

## Availability is not verification

A destination's verification result was established when the transfer finished, by rereading and
hashing every byte. Whether the drive is plugged in today has nothing to do with it, so the two are
reported as separate facts and a missing drive never reads as an unverified one.

| Availability | Meaning |
|---|---|
| `available` | The transfer folder is readable and the volume identifies as the one recorded |
| `indeterminate` | The folder is readable, but the volume cannot identify itself well enough to confirm |
| `mismatched` | Something is mounted where the transfer was written, and it is not the recorded volume |
| `missing` | Nothing readable is there — disconnected, or moved |

Matching uses `VolumeIdentity.relation(to:)`, the same comparison relaunch recovery uses: volume UUID
or partition, never display name or mount path.

## Per-destination results

`HistoryDestinationResult` records copied, verified, mismatched, failed, and conflicted counts for
each destination separately. A verified primary can never stand in for a backup that was not
verified. An index written before these existed decodes to the one thing it actually asserted —
whether a destination was fully verified — and is not embellished.

## Actions, and why they are disabled

Every action is a read: reveal in Finder, open the manifest in whatever reads JSON, or hand the
folder to a companion app. None of them writes to a destination, touches a manifest, or modifies the
index. When an action is unavailable the reason is written out next to it rather than left to a
greyed-out button.

The companion-app handoff (SDelight) is offered only for a destination that is both connected *and*
fully verified, because handing a folder to another app is an invitation to treat those files as the
good copy. If the app is not installed, the action says so. `HandoffTarget` carries candidate bundle
identifiers rather than one, so a rename does not silently turn the action off.

## Paths

The portable manifest carries no mount paths and no bookmark bytes, and history does not change that:
`DestinationPlan` still encodes only id, label, and volume identity. The one path the index keeps is
each destination's manifest location, which is what lets the authoritative record be reopened. It
stays in the app's private support directory and is never written to a log.
