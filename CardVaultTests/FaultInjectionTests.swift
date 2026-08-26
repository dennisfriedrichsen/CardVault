import CryptoKit
import Foundation
import Testing
@testable import CardVaultCore

/// Every test here injects one concrete hardware or process failure and then
/// asks the same four questions of what is left on disk:
///
/// 1. the source is byte-for-byte what it was,
/// 2. the last manifest still decodes,
/// 3. nothing already verified was overwritten or removed,
/// 4. resuming starts at a whole-file boundary.
///
/// Nothing here needs a removable drive: temporary directories plus deterministic
/// fault injection reproduce the situations a card reader produces.
@Suite("Fault injection and interruption reliability")
struct FaultInjectionTests {

    // MARK: - Short reads and short writes

    @Test("A short read while hashing the source stops the transfer instead of recording a digest")
    func shortReadWhileHashingSource() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "second.CR3", effect: .stop(afterBytes: 40_000, reporting: nil))
            ])

            await #expect(throws: FileSystemError.shortRead("second.CR3", bytesRead: 40_000)) {
                try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)
            }

            let manifest = try await fixture.manifest()
            #expect(manifest.state == .interrupted)
            // A partial read must never leave a digest behind for something else to trust.
            #expect(manifest.file("second.CR3").sourceChecksum == nil)
            #expect(fixture.noFileIsVerified(manifest))
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A short read while copying leaves no artifact and no verified claim")
    func shortReadWhileCopying() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            // Pass 0 is the hashing read; the copy is the read that follows it.
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "DCIM/second.CR3", after: 1,
                      effect: .stop(afterBytes: 40_000, reporting: nil))
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            let manifest = try await fixture.manifest()
            let result = fixture.result(manifest, "second.CR3")
            #expect(result.copyState == .failed)
            #expect(result.verification == .pending)
            #expect(result.error?.contains("shortRead") == true)
            #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL("second.CR3").path))
            // The other files are unaffected and independently verified.
            #expect(fixture.result(manifest, "first.CR3").verification == .verified)
            #expect(fixture.result(manifest, "third.jpg").verification == .verified)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A short write is detected and its partial artifact is removed")
    func shortWriteIsDetected() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: "second.CR3", effect: .stop(afterBytes: 40_000, reporting: nil))
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            #expect(outcome.destinations[0].failedFiles == 1)
            let manifest = try await fixture.manifest()
            #expect(fixture.result(manifest, "second.CR3").copyState == .failed)
            #expect(fixture.result(manifest, "second.CR3").error?.contains("shortWrite") == true)
            // Never left behind to be mistaken for a copy.
            #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL("second.CR3").path))
            // A failed destination is never finalised.
            #expect(outcome.destinations[0].finalURL == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.finalRoot().path))
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A short read while verifying never records a verification")
    func shortReadWhileVerifying() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "Originals/DCIM/second.CR3",
                      effect: .stop(afterBytes: 40_000, reporting: nil))
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            let manifest = try await fixture.manifest()
            let result = fixture.result(manifest, "second.CR3")
            #expect(result.copyState == .copied)
            #expect(result.verification == .failed)
            #expect(result.destinationChecksum == nil)
            // Unverifiable is not the same as wrong: the bytes stay for a retry.
            #expect(FileManager.default.fileExists(atPath: fixture.stagedURL("second.CR3").path))
            try await fixture.expectSourceUnchanged(before)
        }
    }

    // MARK: - Disconnection

    @Test("A source that disconnects mid-copy stops the transfer with a decodable record")
    func sourceDisconnectsWhileCopying() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            // The whole card goes away, so every later read of it fails too.
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "/CARD/", after: 2, effect: .fail(.disconnected), repeats: true)
            ])

            await #expect(throws: (any Error).self) {
                try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)
            }

            let manifest = try await fixture.manifest()
            #expect(manifest.state == .interrupted)
            #expect(manifest.errors.contains { $0.contains("disconnected") })
            #expect(fixture.noFileIsVerified(manifest))
            #expect(try await fixture.recoveryScan().transfers.count == 1)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A destination that disconnects mid-copy fails every file without touching the source")
    func destinationDisconnectsWhileCopying() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.write, effect: .fail(.disconnected), repeats: true)
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            #expect(outcome.destinations[0].verifiedFiles == 0)
            let manifest = try await fixture.manifest()
            #expect(manifest.files.allSatisfy { $0.destinations.values.allSatisfy { $0.copyState == .failed } })
            #expect(!FileManager.default.fileExists(atPath: fixture.finalRoot().path))
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A destination that disconnects while verifying keeps the bytes it already wrote")
    func destinationDisconnectsWhileVerifying() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "Originals/", effect: .fail(.disconnected), repeats: true)
            ])
            let coordinator = fixture.coordinator(injector: injector)

            let outcome = try await coordinator.execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            let manifest = try await fixture.manifest()
            #expect(manifest.files.allSatisfy { $0.destinations.values.allSatisfy { $0.verification == .failed } })
            // Unverified is a reason to retry, never a reason to delete.
            for name in fixture.fileNames {
                #expect(try fixture.stagedContents(name) == fixture.contents(name))
            }
            try await fixture.expectSourceUnchanged(before)

            // Reconnecting and resuming verifies the bytes already on disk
            // rather than copying them again.
            let inodes = try fixture.fileNames.map { try fixture.stagedInode($0) }
            let resumed = try await fixture.coordinator().resume(plan: fixture.plan,
                                                                 manifestURL: fixture.manifestURL())
            #expect(resumed.state == .verified)
            #expect(try fixture.fileNames.map { try fixture.stagedInode($0) } == inodes)
        }
    }

    @Test("A source removed before scanning is reported rather than read as an empty card")
    func sourceDisconnectsWhileScanning() async throws {
        try await withFaultFixture { fixture in
            try FileManager.default.removeItem(at: fixture.source)
            #expect(throws: SourceScanError.sourceUnavailable) {
                try SourceScanner().scan(root: fixture.source, mode: .preserveCard)
            }
        }
    }

    // MARK: - Capacity

    @Test("Preflight blocks a destination that cannot hold the transfer")
    func preflightBlocksInsufficientSpace() async throws {
        try await withFaultFixture { fixture in
            let result = TransferPreflightService(safetyMarginBytes: 0) { _ in 1_000 }.validate(fixture.plan)
            #expect(!result.canProceed)
            #expect(result.issues.contains { $0.code == "insufficient-space" && $0.severity == .blocking })
        }
    }

    @Test("A destination that fills up mid-transfer leaves the independent copy verified")
    func destinationBecomesFull() async throws {
        try await withFaultFixture(destinationCount: 2) { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: fixture.destinationRoots[1].lastPathComponent,
                      effect: .stop(afterBytes: 10_000, reporting: .deviceFull), repeats: true)
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .partiallySuccessful)
            #expect(outcome.destinations[0].isVerified)
            #expect(outcome.destinations[0].finalURL != nil)
            #expect(!outcome.destinations[1].isVerified)
            #expect(outcome.destinations[1].finalURL == nil)
            let manifest = try await fixture.manifest()
            #expect(manifest.files.allSatisfy {
                $0.destinations[fixture.plan.destinations[1].id]?.error?.contains("destinationFull") == true
            })
            // Nothing partial survives on the full drive.
            #expect(try fixture.stagedFileCount(index: 1) == 0)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    // MARK: - Permissions and bookmarks

    @Test("A destination that stops accepting writes fails only its own files")
    func permissionDeniedOnDestination() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: "second.CR3", effect: .fail(.permissionDenied))
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            #expect(outcome.destinations[0].verifiedFiles == fixture.fileNames.count - 1)
            let manifest = try await fixture.manifest()
            #expect(fixture.result(manifest, "second.CR3").error?.contains("permissionDenied") == true)
            #expect(fixture.result(manifest, "first.CR3").verification == .verified)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A source file that becomes unreadable fails alone and is never modified")
    func permissionChangeOnSourceFile() async throws {
        try await withFaultFixture { fixture in
            let unreadable = fixture.source.appending(path: "DCIM/second.CR3")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                           ofItemAtPath: unreadable.path) }
            // A process that can read anything (root) cannot exercise this path.
            try #require(!FileManager.default.isReadableFile(atPath: unreadable.path))

            await #expect(throws: (any Error).self) {
                try await fixture.coordinator().execute(plan: fixture.plan)
            }

            let manifest = try await fixture.manifest()
            #expect(manifest.state == .interrupted)
            #expect(fixture.noFileIsVerified(manifest))
            #expect(FileManager.default.fileExists(atPath: unreadable.path))
        }
    }

    @Test("An unresolvable bookmark blocks resume without discarding the transfer")
    func bookmarkResolutionFailure() async throws {
        try await withFaultFixture { fixture in
            let storage = fixture.root.appending(path: "bookmarks.plist")
            let key = BookmarkKey.source(transferID: fixture.plan.id)
            // Bookmark bytes that no longer resolve: the drive was erased, or the
            // record was written by a system that is no longer there.
            try PropertyListEncoder().encode([key: Data("not a bookmark".utf8)]).write(to: storage)
            let store = SecurityScopedBookmarkStore(storageURL: storage)

            await #expect(throws: (any Error).self) { try await store.resolve(key: key) }
            await #expect(throws: BookmarkError.unknownKey) { try await store.resolve(key: BookmarkKey.primary) }

            // With no resolved source the transfer is still offered, still
            // inspectable, and simply cannot be resumed yet.
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "/CARD/", after: 2, effect: .fail(.disconnected), repeats: true)
            ])
            _ = try? await fixture.coordinator(injector: injector).execute(plan: fixture.plan)
            let scan = try await fixture.recoveryScan()
            let transfer = try #require(scan.transfers.first)
            #expect(!transfer.canResume)
            #expect(transfer.blockingReason?.contains("Reconnect") == true)
            await #expect(throws: RecoveryError.sourceUnavailable) {
                try await RecoveryCoordinator().resumePlan(for: transfer)
            }
        }
    }

    // MARK: - Mutation before verification

    @Test("Destination bytes changed before verification are reported as a mismatch")
    func destinationMutatedBeforeVerification() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let target = fixture.stagedURL("second.CR3")
            let corrupted = Data(repeating: 0xAB, count: Int(fixture.fileByteCount))
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "Originals/DCIM/second.CR3",
                      effect: .interpose { try? corrupted.write(to: target) })
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            let manifest = try await fixture.manifest()
            let result = fixture.result(manifest, "second.CR3")
            #expect(result.verification == .mismatch)
            #expect(result.destinationChecksum != manifest.file("second.CR3").sourceChecksum)
            #expect(fixture.result(manifest, "first.CR3").verification == .verified)
            #expect(outcome.destinations[0].finalURL == nil)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A destination truncated before verification fails verification and is kept")
    func destinationTruncatedBeforeVerification() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let target = fixture.stagedURL("second.CR3")
            let injector = FaultInjector(rules: [
                .init(.attributes, pathContains: "Originals/DCIM/second.CR3",
                      effect: .interpose { try? Data(repeating: 1, count: 16).write(to: target) })
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            let result = try await fixture.result(fixture.manifest(), "second.CR3")
            #expect(result.verification == .failed)
            #expect(result.error?.contains("unexpectedEndOfFile") == true)
            #expect(FileManager.default.fileExists(atPath: target.path))
            try await fixture.expectSourceUnchanged(before)
        }
    }

    // MARK: - Source mutation

    @Test("A source file that grows between hashing and copying is never reported as copied")
    func sourceMutatedDuringTransfer() async throws {
        try await withFaultFixture { fixture in
            let mutating = fixture.source.appending(path: "DCIM/second.CR3")
            let grown = Data(repeating: 3, count: Int(fixture.fileByteCount) + 4_096)
            let injector = FaultInjector(rules: [
                .init(.read, pathContains: "DCIM/second.CR3", after: 1,
                      effect: .interpose { try? grown.write(to: mutating) })
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            let manifest = try await fixture.manifest()
            #expect(fixture.result(manifest, "second.CR3").copyState == .failed)
            #expect(fixture.result(manifest, "second.CR3").error?.contains("sourceChanged") == true)
            #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL("second.CR3").path))
            // CardVault changed nothing: the file holds exactly what the test wrote.
            #expect(try Data(contentsOf: mutating) == grown)
            #expect(fixture.result(manifest, "first.CR3").verification == .verified)
        }
    }

    @Test("A source that no longer matches the plan stops before anything is written for it")
    func sourceChangedBeforeTransfer() async throws {
        try await withFaultFixture { fixture in
            let mutating = fixture.source.appending(path: "DCIM/first.CR3")
            try Data(repeating: 9, count: 32).write(to: mutating)

            await #expect(throws: FileSystemError.sourceChanged("DCIM/first.CR3")) {
                try await fixture.coordinator().execute(plan: fixture.plan)
            }

            let manifest = try await fixture.manifest()
            #expect(manifest.state == .interrupted)
            #expect(fixture.noFileIsVerified(manifest))
            #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL("first.CR3").path))
        }
    }

    // MARK: - Sleep and wake

    @Test("A sleep and wake gap mid-copy neither breaks the transfer nor the estimates")
    func sleepAndWakeGap() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
            // The machine sleeps for ten minutes in the middle of one file.
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: "second.CR3", effect: .interpose { clock.advance(600) })
            ])
            let recorder = ProgressRecorder()

            let outcome = try await fixture
                .coordinator(injector: injector, now: { clock.now })
                .execute(plan: fixture.plan) { await recorder.record($0) }

            #expect(outcome.state == .verified)
            #expect(outcome.destinations[0].verifiedFiles == fixture.fileNames.count)
            let snapshots = await recorder.snapshots
            #expect(!snapshots.isEmpty)
            // A stalled clock must never produce a negative rate, an infinite
            // estimate, or a bar that runs backwards.
            #expect(snapshots.allSatisfy { ($0.bytesPerSecond ?? 0) >= 0 })
            #expect(snapshots.allSatisfy { ($0.estimatedSecondsRemaining ?? 0).isFinite })
            #expect(snapshots.allSatisfy { $0.fractionCompleted >= 0 && $0.fractionCompleted <= 1 })
            try await fixture.expectSourceUnchanged(before)
        }
    }

    // MARK: - Cancellation

    @Test("Cancellation stops at a file boundary and leaves a resumable transfer")
    func cancellationAtAFileBoundary() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let rendezvous = Rendezvous()
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: "second.CR3",
                      effect: .interpose { await rendezvous.arriveAndWait() })
            ])
            let coordinator = fixture.coordinator(injector: injector)

            let task = Task { try await coordinator.execute(plan: fixture.plan) }
            await rendezvous.waitForArrival()
            task.cancel()
            await rendezvous.release()

            await #expect(throws: CancellationError.self) { try await task.value }

            let manifest = try await fixture.manifest()
            #expect(manifest.state == .cancelled)
            #expect(manifest.errors.contains { $0.contains("safe file boundary") })
            // The file that was in flight left nothing half-written behind.
            #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL("second.CR3").path))
            #expect(try fixture.stagedContents("first.CR3") == fixture.contents("first.CR3"))
            try await fixture.expectSourceUnchanged(before)

            let resumed = try await fixture.coordinator().resume(plan: fixture.plan,
                                                                 manifestURL: fixture.manifestURL())
            #expect(resumed.state == .verified)
            #expect(resumed.destinations[0].verifiedFiles == fixture.fileNames.count)
        }
    }

    // MARK: - Termination between manifest updates

    @Test("A process that dies between manifest updates leaves the last record decodable")
    func terminationBetweenManifestUpdates() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            // The process stops existing after the fourth durable update: no
            // error path runs, nothing is tidied up, the write simply never lands.
            let budget = SaveBudget(limit: 4)
            let store = ManifestStore { _, _ in await budget.consume() }

            await #expect(throws: (any Error).self) {
                try await fixture.coordinator(manifestStore: store).execute(plan: fixture.plan)
            }

            // Both the current record and its retained predecessor still decode.
            let manifest = try await fixture.manifest()
            #expect(manifest.transferID == fixture.plan.id)
            let previous = try await ManifestStore()
                .load(from: fixture.manifestURL().appendingPathExtension("previous"))
            #expect(previous.transferID == fixture.plan.id)
            #expect(try await fixture.recoveryScan().unreadable.isEmpty)

            // Relaunching resumes from that record and finishes the job.
            let resumed = try await fixture.coordinator().resume(plan: fixture.plan,
                                                                 manifestURL: fixture.manifestURL())
            #expect(resumed.state == .verified)
            #expect(resumed.destinations[0].verifiedFiles == fixture.fileNames.count)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A copy that finishes but is never recorded is verified, not copied again, on resume")
    func terminationAfterCopyBeforeVerificationState() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            // Every update lands until the transfer tries to record that copying
            // finished, which is the moment the copy phase is complete on disk
            // but nothing above it knows.
            let store = ManifestStore { manifest, _ in
                manifest.state == .copying ? nil : FileSystemError.disconnected(.write, "manifest")
            }

            await #expect(throws: (any Error).self) {
                try await fixture.coordinator(manifestStore: store).execute(plan: fixture.plan)
            }

            let manifest = try await fixture.manifest()
            #expect(manifest.state == .copying)
            #expect(manifest.files.allSatisfy { $0.destinations.values.allSatisfy { $0.copyState == .copied } })
            #expect(fixture.noFileIsVerified(manifest))
            let inodes = try fixture.fileNames.map { try fixture.stagedInode($0) }

            let resumed = try await fixture.coordinator().resume(plan: fixture.plan,
                                                                 manifestURL: fixture.manifestURL())

            #expect(resumed.state == .verified)
            // Same inodes: every file was reread and verified, none rewritten.
            #expect(try fixture.fileNames.map { try fixture.stagedInode($0) } == inodes)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    // MARK: - Finalization

    @Test("A failure immediately before finalization keeps staging intact and resumable")
    func failureBeforeFinalization() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [.init(.move, effect: .fail(.disconnected))])

            await #expect(throws: (any Error).self) {
                try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)
            }

            #expect(!FileManager.default.fileExists(atPath: fixture.finalRoot().path))
            let manifest = try await fixture.manifest()
            #expect(manifest.state == .interrupted)
            // The work itself survived; only the rename did not happen.
            #expect(manifest.files.allSatisfy { $0.destinations.values.allSatisfy { $0.verification == .verified } })
            let inodes = try fixture.fileNames.map { try fixture.stagedInode($0) }

            let resumed = try await fixture.coordinator().resume(plan: fixture.plan,
                                                                 manifestURL: fixture.manifestURL())

            #expect(resumed.state == .verified)
            #expect(resumed.destinations[0].finalURL == fixture.finalRoot())
            #expect(try fixture.fileNames.map { try fixture.stagedInode($0) } == inodes)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("A failure immediately after finalization keeps the moved data and offers no phantom transfer")
    func failureAfterFinalization() async throws {
        try await withFaultFixture { fixture in
            let before = try await fixture.sourceSnapshot()
            // Finalisation renames staging to the final name, and the very next
            // durable update never lands.
            let store = ManifestStore { _, url in
                url.path.contains(TransferLayout.incompleteMarker)
                    ? nil : FileSystemError.disconnected(.write, "manifest")
            }

            await #expect(throws: (any Error).self) {
                try await fixture.coordinator(manifestStore: store).execute(plan: fixture.plan)
            }

            // The verified copy is where it belongs, whole.
            #expect(FileManager.default.fileExists(atPath: fixture.finalRoot().path))
            for name in fixture.fileNames {
                #expect(try fixture.stagedContents(name) == fixture.contents(name))
            }
            let manifest = try await fixture.manifest()
            #expect(manifest.state == .verified)
            #expect(manifest.files.allSatisfy { $0.destinations.values.allSatisfy { $0.verification == .verified } })
            // A finished transfer must not be resurrected as an unfinished one.
            let scan = try await fixture.recoveryScan()
            #expect(scan.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.stagingRoot().path))
            try await fixture.expectSourceUnchanged(before)
        }
    }

    // MARK: - Primary and backup, in either order

    @Test("Primary copy failure and backup verification failure are reported independently")
    func primaryCopyThenBackupVerificationFailure() async throws {
        try await withFaultFixture(destinationCount: 2) { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: fixture.destinationRoots[0].lastPathComponent,
                      effect: .fail(.disconnected), repeats: true),
                .init(.read, pathContains: "\(fixture.destinationRoots[1].lastPathComponent)/",
                      effect: .fail(.permissionDenied), repeats: true)
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            #expect(outcome.destinations.allSatisfy { !$0.isVerified && $0.finalURL == nil })
            let manifest = try await fixture.manifest(index: 1)
            let primary = fixture.result(manifest, "first.CR3", index: 0)
            let backup = fixture.result(manifest, "first.CR3", index: 1)
            #expect(primary.copyState == .failed)
            #expect(primary.error?.contains("disconnected") == true)
            #expect(backup.copyState == .copied)
            #expect(backup.verification == .failed)
            #expect(backup.error?.contains("permissionDenied") == true)
            try await fixture.expectSourceUnchanged(before)
        }
    }

    @Test("Backup copy failure and primary verification failure are reported independently")
    func backupCopyThenPrimaryVerificationFailure() async throws {
        try await withFaultFixture(destinationCount: 2) { fixture in
            let before = try await fixture.sourceSnapshot()
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: fixture.destinationRoots[1].lastPathComponent,
                      effect: .fail(.disconnected), repeats: true),
                .init(.read, pathContains: "\(fixture.destinationRoots[0].lastPathComponent)/",
                      effect: .fail(.permissionDenied), repeats: true)
            ])

            let outcome = try await fixture.coordinator(injector: injector).execute(plan: fixture.plan)

            #expect(outcome.state == .failed)
            #expect(outcome.destinations.allSatisfy { !$0.isVerified && $0.finalURL == nil })
            let manifest = try await fixture.manifest(index: 0)
            #expect(fixture.result(manifest, "first.CR3", index: 1).copyState == .failed)
            #expect(fixture.result(manifest, "first.CR3", index: 0).verification == .failed)
            try await fixture.expectSourceUnchanged(before)
        }
    }
}

// MARK: - Test doubles

/// A clock the test moves by hand, so a ten-minute sleep costs no wall time and
/// happens at exactly the same point on every run.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        // Ordinary progress between calls, so rate estimates have something to work with.
        current += 0.01
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}

private actor ProgressRecorder {
    private(set) var snapshots: [TransferProgress] = []
    func record(_ snapshot: TransferProgress) { snapshots.append(snapshot) }
}

/// Accepts a fixed number of manifest saves and then stops accepting any, the
/// way a process that no longer exists does.
private actor SaveBudget {
    private var remaining: Int
    init(limit: Int) { remaining = limit }

    func consume() -> Error? {
        guard remaining > 0 else { return FileSystemError.disconnected(.write, "manifest") }
        remaining -= 1
        return nil
    }
}

/// Holds a transfer at a known point so a test can cancel it there rather than
/// racing the copy loop.
private actor Rendezvous {
    private var arrived: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    private var isReleased = false

    func arriveAndWait() async {
        hasArrived = true
        arrived?.resume()
        arrived = nil
        guard !isReleased else { return }
        await withCheckedContinuation { released = $0 }
    }

    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func release() {
        isReleased = true
        released?.resume()
        released = nil
    }
}

// MARK: - Fixture

private struct SourceEntry: Equatable {
    let byteCount: Int64
    let digest: String
    let inode: Int
}

private struct FaultFixture {
    let root: URL
    let source: URL
    let destinationRoots: [URL]
    let plan: TransferPlan
    let fileNames: [String]
    let fileByteCount: Int64

    // MARK: Building coordinators

    func coordinator(injector: FaultInjector? = nil,
                     manifestStore: ManifestStore = ManifestStore(),
                     now: (@Sendable () -> Date)? = nil) -> TransferCoordinator {
        // A small chunk keeps every fault landing mid-file while the fixture
        // stays small enough to run in a temporary directory.
        TransferCoordinator(fileSystem: LocalFileSystem(injector: injector, chunkBytes: 16_384),
                            manifestStore: manifestStore,
                            tuning: TransferTuning(chunkBytes: 16_384),
                            now: now ?? { Date() })
    }

    // MARK: Locations

    var layout: TransferLayout { TransferLayout(plan: plan) }

    func stagingRoot(index: Int = 0) -> URL { layout.stagingRoot(in: destinationRoots[index]) }

    func finalRoot(index: Int = 0) -> URL { layout.finalRoot(in: destinationRoots[index]) }

    /// The transfer tree wherever it is now: staging until finalisation renames it.
    func treeRoot(index: Int = 0) -> URL {
        let final = finalRoot(index: index)
        return FileManager.default.fileExists(atPath: final.path) ? final : stagingRoot(index: index)
    }

    func manifestURL(index: Int = 0) -> URL {
        TransferLayout.manifestURL(inStaging: treeRoot(index: index))
    }

    func stagedURL(_ name: String, index: Int = 0) -> URL {
        TransferLayout.originalsRoot(inStaging: treeRoot(index: index)).appending(path: "DCIM/\(name)")
    }

    // MARK: Reading what is on disk

    func manifest(index: Int = 0) async throws -> TransferManifest {
        try await ManifestStore().load(from: manifestURL(index: index))
    }

    func contents(_ name: String) throws -> Data {
        try Data(contentsOf: source.appending(path: "DCIM/\(name)"))
    }

    func stagedContents(_ name: String, index: Int = 0) throws -> Data {
        try Data(contentsOf: stagedURL(name, index: index))
    }

    func stagedInode(_ name: String, index: Int = 0) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL(name, index: index).path)
        return attributes[.systemFileNumber] as? Int ?? -1
    }

    func stagedFileCount(index: Int = 0) throws -> Int {
        let originals = TransferLayout.originalsRoot(inStaging: treeRoot(index: index)).appending(path: "DCIM")
        guard FileManager.default.fileExists(atPath: originals.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: originals.path).count
    }

    func result(_ manifest: TransferManifest, _ name: String, index: Int = 0) -> DestinationFileResult {
        manifest.file(name).destinations[plan.destinations[index].id] ?? DestinationFileResult()
    }

    func noFileIsVerified(_ manifest: TransferManifest) -> Bool {
        manifest.files.allSatisfy { $0.destinations.values.allSatisfy { $0.verification != .verified } }
    }

    func recoveryScan() async throws -> RecoveryScan {
        await RecoveryCoordinator().scan(destinationRoots: destinationRoots)
    }

    // MARK: The invariant every test shares

    func sourceSnapshot() async throws -> [String: SourceEntry] {
        var entries: [String: SourceEntry] = [:]
        let fileSystem = LocalFileSystem()
        for name in fileNames {
            let url = source.appending(path: "DCIM/\(name)")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            entries[name] = SourceEntry(byteCount: size,
                                        digest: try await fileSystem.checksum(url, expectedSize: size),
                                        inode: attributes[.systemFileNumber] as? Int ?? -1)
        }
        return entries
    }

    /// The one thing no failure is allowed to change.
    func expectSourceUnchanged(_ before: [String: SourceEntry],
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(try await sourceSnapshot() == before, sourceLocation: sourceLocation)
    }
}

private extension TransferManifest {
    func file(_ name: String) -> ManifestFile {
        files.first { $0.relativeSourcePath.hasSuffix(name) } ?? files[0]
    }
}

private func withFaultFixture(destinationCount: Int = 1,
                              _ body: (FaultFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CardVaultFaultTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appending(path: "CARD")
    try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
    let names = ["first.CR3", "second.CR3", "third.jpg"]
    let byteCount = 200_000
    for (index, name) in names.enumerated() {
        try Data(repeating: UInt8(index + 1), count: byteCount)
            .write(to: source.appending(path: "DCIM/\(name)"))
    }

    let destinationRoots = (0..<destinationCount).map { root.appending(path: "destination-\($0)") }
    for url in destinationRoots { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    let sourceVolume = VolumeIdentity(displayName: "CARD", fileSystem: "exFAT", isRemovable: true,
                                      physicalStoreIdentifier: "source")
    let destinations = destinationRoots.enumerated().map { index, url in
        DestinationPlan(label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                        volume: VolumeIdentity(displayName: url.lastPathComponent, fileSystem: "APFS",
                                               physicalStoreIdentifier: "disk\(index)"))
    }
    let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
    let plan = TransferPlan(name: "Fault Transfer", mode: .preserveCard, sourceRootPath: source.path,
                            sourceVolume: sourceVolume, files: files, destinations: destinations)
    try await body(FaultFixture(root: root, source: source, destinationRoots: destinationRoots,
                                plan: plan, fileNames: names, fileByteCount: Int64(byteCount)))
}
