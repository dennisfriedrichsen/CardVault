import Foundation
import Testing
@testable import CardVaultCore

@Suite("Relaunch recovery for unfinished transfers")
struct RecoveryTests {

    // MARK: - Discovery

    @Test("An interrupted transfer is offered after relaunch")
    func interruptedTransferIsOffered() async throws {
        try await withFixture { fixture in
            // Reading a source attribute fails, so the run dies mid-copy exactly
            // the way a yanked card or a panic would leave it.
            let injector = FaultInjector(rules: [.init(.attributes, pathContains: "second.CR3")])
            await #expect(throws: (any Error).self) {
                try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector))
                    .execute(plan: fixture.plan)
            }

            let scan = await fixture.coordinator().scan(destinationRoots: fixture.destinationRoots)
            #expect(scan.unreadable.isEmpty)
            let transfer = try #require(scan.transfers.first)
            #expect(transfer.id == fixture.plan.id)
            #expect(transfer.name == fixture.plan.name)
            #expect(transfer.lastDurableState == .interrupted)
            #expect(transfer.interruptedOperation == .unknown)
            #expect(transfer.totalFiles == fixture.plan.files.count)
            #expect(transfer.verifiedFiles == 0)
            #expect(transfer.remainingFiles == transfer.totalFiles)
            #expect(!transfer.errors.isEmpty)
        }
    }

    @Test("A finished transfer is a record, not an offer")
    func finishedTransferIsNotOffered() async throws {
        try await withFixture { fixture in
            let outcome = try await TransferCoordinator().execute(plan: fixture.plan)
            #expect(outcome.state == .verified)
            let scan = await fixture.coordinator().scan(destinationRoots: fixture.destinationRoots)
            #expect(scan.isEmpty)
        }
    }

    @Test("The durable state, progress, and failed operation are all presented")
    func presentsDurableProgress() async throws {
        try await withFixture(fileCount: 3) { fixture in
            try await fixture.seedStaging(state: .verifying) { manifest, destinationID in
                manifest.files[0].destinations[destinationID] =
                    DestinationFileResult(copyState: .copied, verification: .verified)
                manifest.files[1].destinations[destinationID] =
                    DestinationFileResult(copyState: .copied, verification: .pending)
                manifest.warnings.append("Backup drive was slower than expected.")
            }
            let transfer = try #require(await fixture.coordinator()
                .scan(destinationRoots: fixture.destinationRoots).transfers.first)
            #expect(transfer.lastDurableState == .verifying)
            #expect(transfer.interruptedOperation == .verifyingFiles)
            #expect(transfer.interruptedOperation.title == "Verifying copied files")
            #expect(transfer.completedFiles == 2)
            #expect(transfer.verifiedFiles == 1)
            #expect(transfer.remainingFiles == 2)
            #expect(transfer.warnings.contains("Backup drive was slower than expected."))
            #expect(transfer.destinations.first?.verifiedFiles == 1)
            #expect(transfer.destinations.first?.copiedFiles == 2)
        }
    }

    // MARK: - Damaged and unsupported manifests

    @Test("A manifest from a newer CardVault is reported and never restarted")
    func unsupportedSchemaIsReported() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            let manifestURL = try fixture.stagingManifestURL()
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any])
            json["schemaVersion"] = TransferManifest.currentSchemaVersion + 1
            try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
            // The rollback copy would otherwise be a readable fallback.
            try? FileManager.default.removeItem(at: manifestURL.appendingPathExtension("previous"))

            let scan = await fixture.coordinator().scan(destinationRoots: fixture.destinationRoots)
            #expect(scan.transfers.isEmpty)
            let unreadable = try #require(scan.unreadable.first)
            #expect(unreadable.isUnsupportedSchema)
            #expect(unreadable.reason.contains("cannot read"))
            #expect(unreadable.transferID == fixture.plan.id)
        }
    }

    @Test("A damaged manifest with no readable fallback is reported, not skipped")
    func damagedManifestIsReported() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            let manifestURL = try fixture.stagingManifestURL()
            try Data("{ this is not json".utf8).write(to: manifestURL)
            try? FileManager.default.removeItem(at: manifestURL.appendingPathExtension("previous"))

            let scan = await fixture.coordinator().scan(destinationRoots: fixture.destinationRoots)
            #expect(scan.transfers.isEmpty)
            #expect(scan.unreadable.count == 1)
            #expect(scan.unreadable[0].isUnsupportedSchema == false)
        }
    }

    @Test("A damaged manifest still recovers from its retained previous copy")
    func damagedManifestUsesPreviousCopy() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            // A second save leaves the first as .previous.
            try await fixture.seedStaging(state: .verifying) { _, _ in }
            try Data("{ truncated".utf8).write(to: try fixture.stagingManifestURL())

            let scan = await fixture.coordinator().scan(destinationRoots: fixture.destinationRoots)
            #expect(scan.unreadable.isEmpty)
            #expect(scan.transfers.count == 1)
        }
    }

    // MARK: - Volume identity

    @Test("A card reinserted at a different mount path is still the same card")
    func reinsertedCardMatches() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            // The source moves from /Volumes/CARD to a new path; identity holds.
            let moved = fixture.root.appending(path: "CARD 1")
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
            let transfer = try #require(await fixture.coordinator()
                .scan(destinationRoots: fixture.destinationRoots,
                      sourceRoots: [fixture.plan.id: .unscoped(moved, wasStale: true)]).transfers.first)
            #expect(transfer.source.match == .matched)
            #expect(transfer.source.bookmarkWasStale)
            #expect(transfer.canResume)
        }
    }

    @Test("A different volume wearing the same name is refused")
    func reformattedCardIsRefused() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            let impostor = fixture.root.appending(path: "impostor")
            try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: true)
            let transfer = try #require(await fixture.coordinator()
                .scan(destinationRoots: fixture.destinationRoots,
                      sourceRoots: [fixture.plan.id: .unscoped(impostor)]).transfers.first)
            #expect(transfer.source.match == .mismatched)
            #expect(!transfer.canResume)
            #expect(transfer.blockingReason?.contains("different volume") == true)
            await #expect(throws: RecoveryError.volumeMismatch(label: "CARD")) {
                try await fixture.coordinator().resumePlan(for: transfer)
            }
        }
    }

    @Test("A missing source blocks resume without hiding the transfer")
    func missingSourceBlocksResume() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            let transfer = try #require(await fixture.coordinator()
                .scan(destinationRoots: fixture.destinationRoots).transfers.first)
            #expect(transfer.source.match == .unavailable)
            #expect(!transfer.canResume)
            #expect(transfer.blockingReason?.contains("Reconnect") == true)
            await #expect(throws: RecoveryError.sourceUnavailable) {
                try await fixture.coordinator().resumePlan(for: transfer)
            }
        }
    }

    // MARK: - Resume

    @Test("A completely copied but unverified file is verified instead of recopied")
    func copiedButUnverifiedIsVerified() async throws {
        try await withFixture(fileCount: 2) { fixture in
            let digest = try await fixture.digest(of: "first.CR3")
            try await fixture.seedStaging(state: .copying) { manifest, destinationID in
                manifest.files[0].sourceChecksum = digest
                manifest.files[0].destinations[destinationID] =
                    DestinationFileResult(copyState: .copied, verification: .pending)
            }
            try fixture.placeCopiedFile("first.CR3")
            let before = try fixture.identity(ofStagedFile: "first.CR3")

            let outcome = try await fixture.resume()
            #expect(outcome.state == .verified)
            // Same inode and same creation date: the bytes were reread, not rewritten.
            #expect(try fixture.identity(ofStagedFile: "first.CR3") == before)

            let manifest = try await fixture.finalManifest()
            let result = try #require(manifest.files[0].destinations[fixture.plan.destinations[0].id])
            #expect(result.verification == .verified)
            #expect(result.destinationChecksum == digest)
        }
    }

    @Test("A recorded incomplete artifact is retried without overwriting verified content")
    func incompleteArtifactRetriedSafely() async throws {
        try await withFixture(fileCount: 2) { fixture in
            let verifiedDigest = try await fixture.digest(of: "first.CR3")
            try await fixture.seedStaging(state: .copying) { manifest, destinationID in
                manifest.files[0].sourceChecksum = verifiedDigest
                manifest.files[0].destinations[destinationID] = DestinationFileResult(
                    copyState: .copied, verification: .verified, destinationChecksum: verifiedDigest)
                // Died mid-write on the second file.
                manifest.files[1].destinations[destinationID] = DestinationFileResult(copyState: .copying)
            }
            try fixture.placeCopiedFile("first.CR3")
            try fixture.placePartialFile("second.CR3")
            let verifiedBefore = try fixture.identity(ofStagedFile: "first.CR3")
            let partialBefore = try fixture.identity(ofStagedFile: "second.CR3")

            let outcome = try await fixture.resume()
            #expect(outcome.state == .verified)
            #expect(outcome.destinations[0].verifiedFiles == 2)
            // The verified file was never rewritten.
            #expect(try fixture.identity(ofStagedFile: "first.CR3") == verifiedBefore)
            // The partial one was replaced and now holds the whole source.
            #expect(try fixture.identity(ofStagedFile: "second.CR3") != partialBefore)
            #expect(try fixture.stagedContents("second.CR3") == fixture.contents("second.CR3"))
        }
    }

    @Test("Resume rebuilds the plan from the manifest, not from a fresh scan")
    func resumePlanComesFromManifest() async throws {
        try await withFixture(fileCount: 2) { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            // A file added to the card after the interruption is not part of the
            // transfer that was interrupted.
            try Data("added later".utf8).write(to: fixture.source.appending(path: "DCIM/late.jpg"))

            let transfer = try #require(await fixture.coordinator()
                .scan(destinationRoots: fixture.destinationRoots,
                      sourceRoots: [fixture.plan.id: .unscoped(fixture.source)]).transfers.first)
            let plan = try await fixture.coordinator().resumePlan(for: transfer)
            #expect(plan.id == fixture.plan.id)
            #expect(plan.name == fixture.plan.name)
            #expect(plan.files.count == 2)
            #expect(!plan.files.contains { $0.relativePath.contains("late.jpg") })
            #expect(plan.destinations.map(\.id) == fixture.plan.destinations.map(\.id))
            #expect(plan.destinations[0].rootPath == fixture.destinationRoots[0].path)
        }
    }

    // MARK: - Inspect

    @Test("Inspection reports every file without modifying any transfer artifact")
    func inspectionIsReadOnly() async throws {
        try await withFixture(fileCount: 2) { fixture in
            try await fixture.seedStaging(state: .verifying) { manifest, destinationID in
                manifest.files[0].destinations[destinationID] =
                    DestinationFileResult(copyState: .copied, verification: .verified)
                manifest.files[1].destinations[destinationID] = DestinationFileResult(
                    copyState: .conflicted, verification: .pending,
                    error: "Unrelated file present", conflict: .unrelatedFile)
            }
            let manifestURL = try fixture.stagingManifestURL()
            let before = try FileManager.default.attributesOfItem(atPath: manifestURL.path)

            let coordinator = fixture.coordinator()
            let transfer = try #require(await coordinator
                .scan(destinationRoots: fixture.destinationRoots).transfers.first)
            let inspection = coordinator.inspect(transfer)

            #expect(inspection.transferID == fixture.plan.id)
            #expect(inspection.files.count == 2)
            #expect(inspection.files[0].destinations[0].verification == .verified)
            #expect(inspection.files[1].destinations[0].conflict == .unrelatedFile)
            #expect(inspection.files[1].destinations[0].error == "Unrelated file present")
            #expect(inspection.manifestURLs.contains(manifestURL))

            let after = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
            #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
            #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
        }
    }

    // MARK: - Abandon

    @Test("Abandoning removes no source file, no verified file, and nothing unrelated")
    func abandonKeepsEverythingThatMatters() async throws {
        try await withFixture(fileCount: 2) { fixture in
            let digest = try await fixture.digest(of: "first.CR3")
            try await fixture.seedStaging(state: .copying) { manifest, destinationID in
                manifest.files[0].sourceChecksum = digest
                manifest.files[0].destinations[destinationID] = DestinationFileResult(
                    copyState: .copied, verification: .verified, destinationChecksum: digest)
                manifest.files[1].destinations[destinationID] = DestinationFileResult(copyState: .copying)
            }
            try fixture.placeCopiedFile("first.CR3")
            try fixture.placePartialFile("second.CR3")
            let unrelated = fixture.destinationRoots[0].appending(path: "family-photos.jpg")
            try Data("not ours".utf8).write(to: unrelated)

            let coordinator = fixture.coordinator()
            let transfer = try #require(await coordinator
                .scan(destinationRoots: fixture.destinationRoots).transfers.first)

            let plan = coordinator.abandonPlan(for: transfer)
            #expect(plan.verifiedFilesKept == 1)
            #expect(plan.removableIncompleteArtifacts.count == 1)
            #expect(plan.removableIncompleteArtifacts[0].lastPathComponent == "second.CR3")

            let outcome = await coordinator.abandon(transfer, removingIncompleteArtifacts: true)
            #expect(outcome.failures.isEmpty)
            #expect(outcome.removedArtifacts.count == 1)

            // Source untouched, verified copy intact, unrelated content intact.
            #expect(FileManager.default.fileExists(atPath: fixture.source.appending(path: "DCIM/first.CR3").path))
            #expect(FileManager.default.fileExists(atPath: fixture.source.appending(path: "DCIM/second.CR3").path))
            #expect(try fixture.stagedContents("first.CR3") == fixture.contents("first.CR3"))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL("second.CR3").path))
            // The record survives so the transfer stays inspectable.
            #expect(FileManager.default.fileExists(atPath: try fixture.stagingManifestURL().path))
        }
    }

    @Test("Abandoning without removing artifacts deletes nothing at all")
    func abandonCanRemoveNothing() async throws {
        try await withFixture(fileCount: 2) { fixture in
            try await fixture.seedStaging(state: .copying) { manifest, destinationID in
                manifest.files[1].destinations[destinationID] = DestinationFileResult(copyState: .copying)
            }
            try fixture.placePartialFile("second.CR3")
            let coordinator = fixture.coordinator()
            let transfer = try #require(await coordinator
                .scan(destinationRoots: fixture.destinationRoots).transfers.first)

            let outcome = await coordinator.abandon(transfer, removingIncompleteArtifacts: false)
            #expect(outcome.removedArtifacts.isEmpty)
            #expect(FileManager.default.fileExists(atPath: fixture.stagedURL("second.CR3").path))
        }
    }

    @Test("An abandoned transfer is no longer offered but stays on disk")
    func abandonedTransferIsNotOffered() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            let coordinator = fixture.coordinator()
            let transfer = try #require(await coordinator
                .scan(destinationRoots: fixture.destinationRoots).transfers.first)
            let outcome = await coordinator.abandon(transfer, removingIncompleteArtifacts: false)
            #expect(outcome.manifestsMarked.count == 1)

            let rescan = await fixture.coordinator().scan(destinationRoots: fixture.destinationRoots)
            #expect(rescan.transfers.isEmpty)
            #expect(rescan.unreadable.isEmpty)
            let manifest = try await ManifestStore().load(from: try fixture.stagingManifestURL())
            #expect(manifest.abandonedAt != nil)
            #expect(manifest.warnings.contains { $0.contains("Abandoned by the user") })
        }
    }

    // MARK: - Layout and bookmark keys

    @Test("A staging directory name round trips its transfer identity")
    func layoutRoundTrip() {
        let id = UUID()
        let layout = TransferLayout(transferID: id, transferName: "Trip/2026")
        #expect(layout.safeName == "Trip-2026")
        let staging = layout.stagingRoot(in: URL(filePath: "/Volumes/Drive"))
        #expect(TransferLayout.transferID(fromStagingName: staging.lastPathComponent) == id)
        #expect(TransferLayout.transferID(fromStagingName: ".DS_Store") == nil)
        #expect(TransferLayout.transferID(fromStagingName: "Trip-2026") == nil)
    }

    @Test("Per-transfer bookmark keys round trip their transfer identity")
    func bookmarkKeyRoundTrip() {
        let transferID = UUID()
        let destinationID = UUID()
        #expect(BookmarkKey.transferID(fromKey: BookmarkKey.source(transferID: transferID)) == transferID)
        #expect(BookmarkKey.transferID(
            fromKey: BookmarkKey.destination(transferID: transferID, destinationID: destinationID)) == transferID)
        #expect(BookmarkKey.transferID(fromKey: BookmarkKey.primary) == nil)
    }

    @Test("A manifest written before the abandoned marker still decodes")
    func decodesManifestWithoutAbandonedMarker() async throws {
        try await withFixture { fixture in
            try await fixture.seedStaging(state: .copying) { _, _ in }
            let url = try fixture.stagingManifestURL()
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any])
            json["abandonedAt"] = nil
            json.removeValue(forKey: "abandonedAt")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            let manifest = try await ManifestStore().load(from: url)
            #expect(manifest.abandonedAt == nil)
            #expect(manifest.transferID == fixture.plan.id)
        }
    }
}

// MARK: - Fixture

/// Identity of a file on disk, used to prove a file was left alone rather than
/// rewritten with the same bytes.
private struct FileIdentity: Equatable {
    let inode: Int
    let created: Date?
}

private struct RecoveryFixture {
    let root: URL
    let source: URL
    let destinationRoots: [URL]
    let plan: TransferPlan
    /// Maps each path to the volume UUID the test resolver should report, so
    /// "same volume at a new path" and "different volume, same name" are both
    /// expressible without mounting anything.
    let volumeUUIDs: [String: UUID]

    func coordinator() -> RecoveryCoordinator {
        let table = volumeUUIDs
        return RecoveryCoordinator(
            resolver: VolumeIdentityResolver(provider: nil, factsProvider: { url in
                URLResourceVolumeFacts(volumeUUID: table[url.standardizedFileURL.path],
                                       volumeName: url.lastPathComponent,
                                       fileSystem: "APFS", isLocal: true, isRemovable: false)
            }))
    }

    var layout: TransferLayout { TransferLayout(plan: plan) }

    func stagingRoot(_ index: Int = 0) -> URL { layout.stagingRoot(in: destinationRoots[index]) }

    func stagingManifestURL(_ index: Int = 0) throws -> URL {
        TransferLayout.manifestURL(inStaging: stagingRoot(index))
    }

    /// Where a file lives now. A finished resume renames staging to the final
    /// root, so this follows the move; the inode survives the rename, which is
    /// what lets the tests prove a file was not rewritten.
    func stagedURL(_ name: String, index: Int = 0) -> URL {
        let final = layout.finalRoot(in: destinationRoots[index])
        let base = FileManager.default.fileExists(atPath: final.path) ? final : stagingRoot(index)
        return TransferLayout.originalsRoot(inStaging: base).appending(path: "DCIM/\(name)")
    }

    func contents(_ name: String) throws -> Data {
        try Data(contentsOf: source.appending(path: "DCIM/\(name)"))
    }

    func stagedContents(_ name: String, index: Int = 0) throws -> Data {
        try Data(contentsOf: stagedURL(name, index: index))
    }

    func digest(of name: String) async throws -> String {
        let url = source.appending(path: "DCIM/\(name)")
        let size = try Data(contentsOf: url).count
        return try await LocalFileSystem().checksum(url, expectedSize: Int64(size))
    }

    func identity(ofStagedFile name: String, index: Int = 0) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL(name, index: index).path)
        return FileIdentity(inode: attributes[.systemFileNumber] as? Int ?? -1,
                            created: attributes[.creationDate] as? Date)
    }

    /// Writes a durable manifest into staging the way an interrupted run would
    /// have left one, then hands it to the caller to record per-file progress.
    func seedStaging(state: TransferState,
                     _ configure: (inout TransferManifest, UUID) -> Void) async throws {
        for (index, _) in destinationRoots.enumerated() {
            try FileManager.default.createDirectory(
                at: TransferLayout.originalsRoot(inStaging: stagingRoot(index)).appending(path: "DCIM"),
                withIntermediateDirectories: true)
        }
        var manifest = TransferManifest(plan: plan)
        manifest.state = state
        manifest.startedAt = Date()
        configure(&manifest, plan.destinations[0].id)
        for index in destinationRoots.indices {
            try await ManifestStore().save(manifest, to: try stagingManifestURL(index))
        }
    }

    func placeCopiedFile(_ name: String, index: Int = 0) throws {
        try contents(name).write(to: stagedURL(name, index: index))
    }

    func placePartialFile(_ name: String, index: Int = 0) throws {
        try contents(name).prefix(3).write(to: stagedURL(name, index: index))
    }

    func finalManifest(_ index: Int = 0) async throws -> TransferManifest {
        let final = layout.finalRoot(in: destinationRoots[index])
        let url = FileManager.default.fileExists(atPath: final.path)
            ? TransferLayout.manifestURL(inStaging: final)
            : try stagingManifestURL(index)
        return try await ManifestStore().load(from: url)
    }

    /// The full relaunch path: discover, rebuild the plan, resume.
    func resume() async throws -> TransferOutcome {
        let recovery = coordinator()
        let scan = await recovery.scan(destinationRoots: destinationRoots,
                                       sourceRoots: [plan.id: .unscoped(source)])
        guard let transfer = scan.transfers.first else { throw RecoveryError.sourceUnavailable }
        let resumePlan = try await recovery.resumePlan(for: transfer)
        let manifestURL = try await recovery.resumeManifestURL(for: transfer)
        return try await TransferCoordinator().resume(plan: resumePlan, manifestURL: manifestURL)
    }
}

private func withFixture(fileCount: Int = 2, destinationCount: Int = 1,
                         _ body: (RecoveryFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CardVaultRecoveryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appending(path: "CARD")
    try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
    let names = ["first.CR3", "second.CR3", "third.jpg"]
    for name in names.prefix(fileCount) {
        try Data("contents of \(name) padded out a little".utf8)
            .write(to: source.appending(path: "DCIM/\(name)"))
    }

    let destinationRoots = (0..<destinationCount).map { root.appending(path: "destination-\($0)") }
    for url in destinationRoots { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    // Stable identities the test resolver will reproduce for these paths, plus
    // one for the same card at a different mount point.
    let sourceUUID = UUID()
    var volumeUUIDs: [String: UUID] = [source.standardizedFileURL.path: sourceUUID,
                                       root.appending(path: "CARD 1").standardizedFileURL.path: sourceUUID,
                                       root.appending(path: "impostor").standardizedFileURL.path: UUID()]
    let sourceVolume = VolumeIdentity(volumeUUID: sourceUUID, resourceIdentifier: sourceUUID.uuidString,
                                      displayName: "CARD", fileSystem: "exFAT", isRemovable: true)
    let destinations = destinationRoots.enumerated().map { index, url -> DestinationPlan in
        let uuid = UUID()
        volumeUUIDs[url.standardizedFileURL.path] = uuid
        return DestinationPlan(id: UUID(), label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                               volume: VolumeIdentity(volumeUUID: uuid, resourceIdentifier: uuid.uuidString,
                                                      displayName: url.lastPathComponent, fileSystem: "APFS"))
    }
    let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
    let plan = TransferPlan(name: "Recovery Transfer", mode: .preserveCard, sourceRootPath: source.path,
                            sourceVolume: sourceVolume, files: files, destinations: destinations)
    try await body(RecoveryFixture(root: root, source: source, destinationRoots: destinationRoots,
                                   plan: plan, volumeUUIDs: volumeUUIDs))
}
