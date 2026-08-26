# Fault injection and interruption coverage

Interruption recovery is only trustworthy if the failures it claims to survive are actually
reproduced. This document describes the fault-injection facilities in `CardVaultCore` and maps every
failure mode to the automated test that exercises it.

None of these tests needs removable media, an administrator, or a network. They run in temporary
directories, they are deterministic, and they make no assumption about how fast the underlying disk
is. The [manual removable-media procedure](manual-removable-media-test.md) remains the check against
real hardware; it does not replace any of this.

## The four invariants

Every test in `CardVaultTests/FaultInjectionTests.swift` injects one concrete failure and then asks
the same four questions of what is left on disk:

1. **The source is byte-for-byte what it was.** Each test snapshots every source file's size,
   SHA-256, and inode before the fault and compares it afterwards.
2. **The last manifest still decodes.** The record is the authoritative state; a failure that leaves
   it unreadable would strand the transfer.
3. **Nothing already verified was overwritten or removed.** Verified files are compared by inode, so
   a rewrite with identical bytes still fails the assertion.
4. **Resuming starts at an accurate whole-file boundary.** Where the scenario is resumable, the test
   resumes it and requires the transfer to finish verified.

## Injection facilities

`FaultInjector` matches a `FileSystemOperation` (`read`, `write`, `createDirectory`, `remove`,
`move`, `attributes`) against an optional path substring, optionally after a number of passes, and
applies one `Effect`:

| Effect | Models |
| --- | --- |
| `.fail(kind)` | An operation that fails before a byte moves. `kind` is `generic`, `disconnected`, `permissionDenied`, or `deviceFull`. |
| `.stop(afterBytes:reporting:)` | An operation that moves some bytes and then stops. A `nil` kind is a silently short read or write; a kind is a device that reports why it stopped. |
| `.interpose(_:)` | A closure run at the operation boundary before the operation proceeds: used to change a file underneath the transfer, to open a sleep/wake gap, or to cancel at a known point. |

A rule marked `repeats` is a condition rather than an event — a volume that is gone stays gone for
every operation that follows, including the ones on the error path.

Manifest durability has its own seam. `ManifestStore(beforeSave:)` takes an interceptor that sees
each manifest and its destination URL and may refuse the write. Refusing every write from a chosen
point on is what a process that stops existing between two manifest updates looks like to everything
above the store: no error handling runs, nothing is tidied up, the record simply never lands.

## Coverage

| Failure mode | Test |
| --- | --- |
| Short read while hashing the source | `shortReadWhileHashingSource` |
| Short read while copying | `shortReadWhileCopying` |
| Short write | `shortWriteIsDetected` |
| Short read while verifying | `shortReadWhileVerifying` |
| Source disconnected while scanning | `sourceDisconnectsWhileScanning` |
| Source disconnected while copying | `sourceDisconnectsWhileCopying` |
| Destination disconnected while copying | `destinationDisconnectsWhileCopying` |
| Destination disconnected while verifying | `destinationDisconnectsWhileVerifying` |
| Destination too small to begin with | `preflightBlocksInsufficientSpace` |
| Destination becoming full mid-transfer | `destinationBecomesFull` |
| Destination permission change | `permissionDeniedOnDestination` |
| Source permission change | `permissionChangeOnSourceFile` |
| Bookmark resolution failure | `bookmarkResolutionFailure` |
| Checksum corruption before verification | `destinationMutatedBeforeVerification` |
| Destination truncated before verification | `destinationTruncatedBeforeVerification` |
| Source mutation during transfer | `sourceMutatedDuringTransfer`, `sourceChangedBeforeTransfer` |
| Sleep and wake | `sleepAndWakeGap` |
| Cancellation | `cancellationAtAFileBoundary` |
| Termination between manifest updates | `terminationBetweenManifestUpdates` |
| Failure after copy, before verification state is persisted | `terminationAfterCopyBeforeVerificationState` |
| Failure immediately before finalization | `failureBeforeFinalization` |
| Failure immediately after finalization | `failureAfterFinalization` |
| Primary and backup failures, in either order | `primaryCopyThenBackupVerificationFailure`, `backupCopyThenPrimaryVerificationFailure` |

## Notes on two of the harder cases

**Sleep and wake.** The coordinator's clock is injected, so the test advances it by ten minutes in
the middle of a file without costing ten minutes of wall time. The transfer must still complete and
verify, and no published progress snapshot may carry a negative rate, a non-finite estimate, or a
fraction outside `0...1`.

**Cancellation.** Cancelling mid-copy races the copy loop, so the test parks the transfer at a known
byte boundary with an interposed rendezvous, cancels there, and then releases it. The file in flight
must leave nothing half-written behind, the record must say `cancelled`, and resuming must finish the
transfer verified.

**Failure after finalization.** Finalisation renames the staging tree to its final name. If the
update that follows the rename cannot land, the error path must not recreate the staging directory it
would otherwise write into: doing so would offer the user an unfinished transfer that had in fact
finished, and that offer could never be resumed. Error-path persistence therefore writes only to
staging trees that still exist.
