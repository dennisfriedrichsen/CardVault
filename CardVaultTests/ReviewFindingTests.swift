import Foundation
import Testing
@testable import CardVaultCore

/// Reproductions for the defects found in the security and correctness review.
///
/// Each test asserts the behaviour the contracts in `Docs/` promise, so a failure
/// here *is* the finding, and each one started failing before its fix existed.
///
/// A test here may still need editing once its fix lands, and #63 is why this no
/// longer says otherwise. That fix refused a traversing path a layer earlier than
/// the reproduction expected — on decode, so the record never becomes a transfer
/// at all — which left the reproduction asking for a transfer that no longer
/// exists. A fix stronger than the reproduction is the outcome to want; the test
/// is then rewritten to assert the stronger behaviour, not treated as a
/// regression. What must not change is the guarantee each test is about.
///
/// - #59 `partiallySuccessfulTransferIsOfferedForRecovery`
/// - #63 `forgedManifestIsRefusedBeforeItIsOffered`,
///   `abandonRefusesAPathOutsideTheStagingTree`, `tamperedManifestCannotEscapeOnResume`
/// - #60 `resumeRechecksSkippedFiles`
@Suite("Review findings")
struct ReviewFindingTests {

    // MARK: - #59 — durable state after a partial success

    @Test("A partially successful transfer is still offered for recovery")
    func partiallySuccessfulTransferIsOfferedForRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CVReviewA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "CARD")
        try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
        let names = ["first.CR3", "second.CR3", "third.jpg"]
        for (index, name) in names.enumerated() {
            try Data(repeating: UInt8(index + 1), count: 200_000)
                .write(to: source.appending(path: "DCIM/\(name)"))
        }
        let destinationRoots = (0..<2).map { root.appending(path: "destination-\($0)") }
        for url in destinationRoots { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

        let destinations = destinationRoots.enumerated().map { index, url in
            DestinationPlan(label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                            volume: VolumeIdentity(displayName: url.lastPathComponent, fileSystem: "APFS",
                                                   physicalStoreIdentifier: "disk\(index)"))
        }
        let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
        let plan = TransferPlan(name: "Partial Transfer", mode: .preserveCard, sourceRootPath: source.path,
                                sourceVolume: VolumeIdentity(displayName: "CARD", fileSystem: "exFAT",
                                                             isRemovable: true, physicalStoreIdentifier: "source"),
                                files: files, destinations: destinations)

        // The backup drive refuses exactly one file: the second write aimed at it.
        let injector = FaultInjector(rules: [
            .init(.write, pathContains: "destination-1", after: 1, effect: .fail(.deviceFull))
        ])
        let coordinator = TransferCoordinator(fileSystem: LocalFileSystem(injector: injector, chunkBytes: 16_384),
                                              tuning: TransferTuning(chunkBytes: 16_384))
        let outcome = try await coordinator.execute(plan: plan)

        // Precondition: the primary verified, the backup did not.
        #expect(outcome.state == .partiallySuccessful)
        #expect(outcome.destinations[0].isVerified)
        #expect(!outcome.destinations[1].isVerified)

        let layout = TransferLayout(plan: plan)
        let backupStaging = layout.stagingRoot(in: destinationRoots[1])
        #expect(FileManager.default.fileExists(atPath: backupStaging.path))

        // The durable record on the unfinished backup should still say what
        // happened to it, not that the whole transfer is done.
        let manifest = try await ManifestStore().load(from: TransferLayout.manifestURL(inStaging: backupStaging))
        #expect(manifest.state == .partiallySuccessful)

        // And relaunch recovery should offer the unfinished backup.
        let scan = await RecoveryCoordinator().scan(destinationRoots: destinationRoots)
        #expect(scan.transfers.count == 1)
    }

    // MARK: - #63 — path traversal via the manifest

    /// The outer layer: a record whose path leads out of the transfer's tree is
    /// refused when it is read, so it never becomes something the user can act on.
    /// The traversal is the reason it is refused, not a decoding accident — the
    /// user is told the record cannot be trusted, and specifically not told to go
    /// and update CardVault, which is what an unsupported schema would mean.
    @Test("A forged manifest is refused when it is read, not when it is acted on")
    func forgedManifestIsRefusedBeforeItIsOffered() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CVReviewB-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A file that has nothing to do with CardVault, outside every destination.
        let victim = root.appending(path: "irreplaceable.jpg")
        try Data(repeating: 0xAB, count: 1_024).write(to: victim)

        let destination = root.appending(path: "destination-0")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // A manifest an attacker (or corruption) wrote onto the destination drive.
        let plan = forgedPlan(destination: destination)
        var forged = TransferManifest(plan: plan)
        forged.state = .copying
        forged.files[0].relativeDestinationPath = "../../../irreplaceable.jpg"
        forged.files[0].destinations[plan.destinations[0].id]?.copyState = .copying

        let layout = TransferLayout(plan: plan)
        let staging = layout.stagingRoot(in: destination)
        try FileManager.default.createDirectory(at: TransferLayout.originalsRoot(inStaging: staging),
                                                withIntermediateDirectories: true)
        let manifestURL = TransferLayout.manifestURL(inStaging: staging)
        try await ManifestStore().save(forged, to: manifestURL)

        let recovery = RecoveryCoordinator()
        let scan = await recovery.scan(destinationRoots: [destination])

        #expect(scan.transfers.isEmpty, "a record that could escape its tree was offered for recovery")
        let refused = try #require(scan.unreadable.first)
        #expect(scan.unreadable.count == 1)
        #expect(refused.manifestURL.standardizedFileURL == manifestURL.standardizedFileURL)
        // Named so the user can see which record is untrustworthy and why.
        #expect(refused.reason.contains("../../../irreplaceable.jpg"))
        #expect(refused.reason.localizedCaseInsensitiveContains("outside"))
        // Updating CardVault would not help and would misplace the blame.
        #expect(!refused.isUnsupportedSchema)

        // Refusing to read it is not enough on its own: nothing may have been
        // touched on the way to that decision either.
        #expect(FileManager.default.fileExists(atPath: victim.path),
                "a file outside the transfer was deleted")
    }

    /// The inner layer, which the guarantee deliberately does not rest on decoding
    /// alone. The manifest is handed to `abandonPlan` directly, because decode is
    /// the outer layer and is exactly what this test has to get past to reach the
    /// site that turns a recorded path into a deletion.
    @Test("Abandon refuses a recorded path that leads outside the staging tree")
    func abandonRefusesAPathOutsideTheStagingTree() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CVReviewB2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let victim = root.appending(path: "irreplaceable.jpg")
        let victimBytes = Data(repeating: 0xAB, count: 1_024)
        try victimBytes.write(to: victim)

        let destination = root.appending(path: "destination-0")
        let plan = forgedPlan(destination: destination)
        let layout = TransferLayout(plan: plan)
        let staging = layout.stagingRoot(in: destination)
        let originals = TransferLayout.originalsRoot(inStaging: staging)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)

        // One real partial artifact, and one record that walks out of the tree.
        // The genuine one has to survive, or "refuses everything" would pass this.
        let partial = originals.appending(path: "DCIM/decoy.CR3")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 512).write(to: partial)

        var manifest = TransferManifest(plan: plan)
        manifest.state = .copying
        manifest.files[0].destinations[plan.destinations[0].id]?.copyState = .copying
        var escaping = manifest.files[0]
        escaping.relativeSourcePath = "DCIM/escape.CR3"
        escaping.relativeDestinationPath = "../../../irreplaceable.jpg"
        manifest.files.append(escaping)

        let manifestURL = TransferLayout.manifestURL(inStaging: staging)
        let recovered = RecoverableTransfer(
            manifest: manifest,
            source: RecoveredSource(recordedVolume: plan.sourceVolume, root: nil,
                                    match: .unavailable, bookmarkWasStale: false),
            destinations: [RecoveredDestination(
                id: plan.destinations[0].id, label: "Primary",
                recordedVolume: plan.destinations[0].volume, root: destination,
                stagingRoot: staging, manifestURL: manifestURL,
                match: .indeterminate, bookmarkWasStale: false,
                copiedFiles: 0, verifiedFiles: 0, conflictedFiles: 0)])

        let recovery = RecoveryCoordinator()
        let abandonPlan = recovery.abandonPlan(for: recovered)

        #expect(abandonPlan.refusedPaths == ["Primary — ../../../irreplaceable.jpg"])
        for url in abandonPlan.removableIncompleteArtifacts {
            #expect(url.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/"),
                    "abandon would remove \(url.standardizedFileURL.path), outside \(staging.path)")
        }
        // The artifact this transfer really did write is still offered, so the
        // refusal is aimed at the escaping path and not at the whole record.
        #expect(abandonPlan.removableIncompleteArtifacts.map(\.standardizedFileURL) == [partial.standardizedFileURL])

        _ = await recovery.abandon(recovered, removingIncompleteArtifacts: true)
        #expect(FileManager.default.fileExists(atPath: victim.path),
                "a file outside the transfer was deleted")
        #expect(try Data(contentsOf: victim) == victimBytes, "a file outside the transfer was overwritten")
        #expect(!FileManager.default.fileExists(atPath: partial.path),
                "the transfer's own partial artifact was not removed")
    }

    private func forgedPlan(destination: URL) -> TransferPlan {
        TransferPlan(
            name: "Forged", mode: .preserveCard, sourceRootPath: "/nonexistent",
            sourceVolume: VolumeIdentity(displayName: "CARD", isRemovable: true),
            files: [SourceFile(relativePath: "DCIM/decoy.CR3", byteCount: 1_024, mediaKind: .raw)],
            destinations: [DestinationPlan(label: "Primary", rootPath: destination.path,
                                           volume: VolumeIdentity(displayName: "destination-0"))])
    }
}

extension ReviewFindingTests {

    // MARK: - #63 — path traversal, silent variant

    @Test("A tampered manifest cannot make resume delete and overwrite outside the staging tree")
    func tamperedManifestCannotEscapeOnResume() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CVReviewC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "CARD")
        try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 2_048).write(to: source.appending(path: "DCIM/real.CR3"))

        let destination = root.appending(path: "destination-0")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        // A photo from an earlier, unrelated import sitting beside the destination.
        let victim = root.appending(path: "earlier-import.jpg")
        let victimBytes = Data(repeating: 0xEE, count: 4_096)
        try victimBytes.write(to: victim)

        let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
        let plan = TransferPlan(
            name: "Tampered", mode: .preserveCard, sourceRootPath: source.path,
            sourceVolume: VolumeIdentity(displayName: "CARD", isRemovable: true),
            files: files,
            destinations: [DestinationPlan(label: "Primary", rootPath: destination.path,
                                           volume: VolumeIdentity(displayName: "destination-0"))])

        // An interrupted transfer's record, as edited on the destination drive.
        var tampered = TransferManifest(plan: plan)
        tampered.state = .copying
        tampered.files[0].relativeDestinationPath = "../../../earlier-import.jpg"
        tampered.files[0].destinations[plan.destinations[0].id]?.copyState = .copying

        let layout = TransferLayout(plan: plan)
        let staging = layout.stagingRoot(in: destination)
        try FileManager.default.createDirectory(at: TransferLayout.originalsRoot(inStaging: staging),
                                                withIntermediateDirectories: true)
        let manifestURL = TransferLayout.manifestURL(inStaging: staging)
        try await ManifestStore().save(tampered, to: manifestURL)

        _ = try? await TransferCoordinator().resume(plan: plan, manifestURL: manifestURL)

        #expect(FileManager.default.fileExists(atPath: victim.path), "an unrelated file was removed")
        #expect(try Data(contentsOf: victim) == victimBytes, "an unrelated file was overwritten")
    }
}

extension ReviewFindingTests {

    // MARK: - #60 — a skipped file is never rechecked

    @Test("Resume does not finalize a skipped file that has since vanished as verified")
    func resumeRechecksSkippedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CVReviewD-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "CARD")
        try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
        for (index, name) in ["a.CR3", "b.CR3"].enumerated() {
            try Data(repeating: UInt8(index + 1), count: 4_096).write(to: source.appending(path: "DCIM/\(name)"))
        }
        let destination = root.appending(path: "destination-0")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
        let plan = TransferPlan(
            name: "Skip Resume", mode: .preserveCard, sourceRootPath: source.path,
            sourceVolume: VolumeIdentity(displayName: "CARD", isRemovable: true),
            files: files,
            destinations: [DestinationPlan(label: "Primary", rootPath: destination.path,
                                           volume: VolumeIdentity(displayName: "destination-0"))])
        let destinationID = plan.destinations[0].id
        let layout = TransferLayout(plan: plan)
        let staging = layout.stagingRoot(in: destination)
        let originals = TransferLayout.originalsRoot(inStaging: staging)
        try FileManager.default.createDirectory(at: originals.appending(path: "DCIM"),
                                                withIntermediateDirectories: true)

        // An interrupted run that had already established "a.CR3" by rereading
        // an existing copy: recorded skipped and verified.
        var manifest = TransferManifest(plan: plan)
        manifest.state = .copying
        let fileSystem = LocalFileSystem()
        let digest = try await fileSystem.checksum(source.appending(path: "DCIM/a.CR3"))
        let index = try #require(manifest.files.firstIndex { $0.relativeSourcePath.hasSuffix("a.CR3") })
        manifest.files[index].sourceChecksum = digest
        manifest.files[index].destinations[destinationID] = DestinationFileResult(
            copyState: .skipped, verification: .verified, destinationChecksum: digest,
            conflict: .contentIdentical)
        let manifestURL = TransferLayout.manifestURL(inStaging: staging)
        try await ManifestStore().save(manifest, to: manifestURL)

        // The copy that claim rests on is not there any more.
        #expect(!FileManager.default.fileExists(atPath: originals.appending(path: "DCIM/a.CR3").path))

        let outcome = try await TransferCoordinator().resume(plan: plan, manifestURL: manifestURL)

        let final = layout.finalRoot(in: destination)
        let missing = !FileManager.default.fileExists(
            atPath: TransferLayout.originalsRoot(inStaging: final).appending(path: "DCIM/a.CR3").path)
        #expect(!(outcome.destinations[0].isVerified && missing),
                "the transfer finalized as verified with a file that is not on the destination")
    }
}
