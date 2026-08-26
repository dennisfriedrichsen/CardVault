import Foundation
import Testing
@testable import CardVaultCore

@Suite("Duplicate and destination conflict classification")
struct ConflictTests {

    // MARK: - Classifier

    @Test("A matching name and byte count alone never classifies as satisfied")
    func nameAndSizeAreNotEvidence() async throws {
        try await withTemporaryDirectory { root in
            let existing = root.appending(path: "photo.CR3")
            let existingBytes = Data("different but same length".utf8)
            let sourceBytes = Data("same length but different".utf8)
            #expect(existingBytes.count == sourceBytes.count)
            try existingBytes.write(to: existing)
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: Int64(sourceBytes.count),
                                sourceChecksum: try await digest(of: sourceBytes),
                                currentResult: nil, compatibleRecord: nil),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .unrelatedFile)
            #expect(!assessment.classification.isSatisfied)
            #expect(assessment.existingByteCount == Int64(existingBytes.count))
        }
    }

    @Test("Identical content is recognised only after the destination bytes are hashed")
    func identicalContent() async throws {
        try await withTemporaryDirectory { root in
            let payload = Data("identical bytes".utf8)
            let existing = root.appending(path: "photo.CR3")
            try payload.write(to: existing)
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: Int64(payload.count),
                                sourceChecksum: try await digest(of: payload),
                                currentResult: nil, compatibleRecord: nil),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .contentIdentical)
            #expect(assessment.existingChecksum == (try await digest(of: payload)))
        }
    }

    @Test("A partial artifact this transfer recorded is replaceable")
    func incompletePriorCopy() async throws {
        try await withTemporaryDirectory { root in
            let existing = root.appending(path: "photo.CR3")
            try Data("half".utf8).write(to: existing)
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: 8,
                                sourceChecksum: try await digest(of: Data("complete".utf8)),
                                currentResult: DestinationFileResult(copyState: .copying),
                                compatibleRecord: nil),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .incompletePriorCopy)
            #expect(assessment.classification.isReplaceable)
        }
    }

    @Test("A file recorded as verified whose bytes changed is ambiguous, not trusted")
    func mutatedAfterVerification() async throws {
        try await withTemporaryDirectory { root in
            let existing = root.appending(path: "photo.CR3")
            try Data("mutated".utf8).write(to: existing)
            let sourceDigest = try await digest(of: Data("original".utf8))
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: 8,
                                sourceChecksum: sourceDigest,
                                currentResult: DestinationFileResult(copyState: .copied, verification: .verified,
                                                                     destinationChecksum: sourceDigest),
                                compatibleRecord: nil),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .ambiguous)
            #expect(assessment.classification.requiresAttention)
        }
    }

    @Test("A copied but unverified file is confirmed by rereading instead of recopied")
    func copiedButUnverified() async throws {
        try await withTemporaryDirectory { root in
            let payload = Data("already written".utf8)
            let existing = root.appending(path: "photo.CR3")
            try payload.write(to: existing)
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: Int64(payload.count),
                                sourceChecksum: try await digest(of: payload),
                                currentResult: DestinationFileResult(copyState: .copied, verification: .pending),
                                compatibleRecord: nil),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .contentIdentical)
            #expect(assessment.classification.isSatisfied)
        }
    }

    @Test("An unknown source checksum is ambiguous rather than assumed safe")
    func unknownSourceChecksum() async throws {
        try await withTemporaryDirectory { root in
            let existing = root.appending(path: "photo.CR3")
            try Data("bytes".utf8).write(to: existing)
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: 5, sourceChecksum: nil,
                                currentResult: nil, compatibleRecord: nil),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .ambiguous)
        }
    }

    @Test("A compatible manifest verifies a file, confirmed by rereading its bytes")
    func compatibleManifest() async throws {
        try await withTemporaryDirectory { root in
            let payload = Data("shared photo".utf8)
            let existing = root.appending(path: "photo.CR3")
            try payload.write(to: existing)
            let checksum = try await digest(of: payload)
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: Int64(payload.count),
                                sourceChecksum: checksum, currentResult: nil,
                                compatibleRecord: .init(transferID: UUID(), transferName: "Yesterday",
                                                        sourceChecksum: checksum, byteCount: Int64(payload.count))),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .verifiedByCompatibleManifest)
            #expect(assessment.explanation.contains("Yesterday"))
        }
    }

    @Test("A compatible manifest tying the path to other content is a different-content conflict")
    func compatibleManifestDisagrees() async throws {
        try await withTemporaryDirectory { root in
            let payload = Data("todays photo".utf8)
            let existing = root.appending(path: "photo.CR3")
            try payload.write(to: existing)
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: Int64(payload.count),
                                sourceChecksum: try await digest(of: Data("a different source".utf8)),
                                currentResult: nil,
                                compatibleRecord: .init(transferID: UUID(), transferName: "Yesterday",
                                                        sourceChecksum: try await digest(of: payload),
                                                        byteCount: Int64(payload.count))),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .differentContent)
            #expect(assessment.classification.requiresAttention)
        }
    }

    @Test("A manifest claiming verification the bytes contradict is ambiguous")
    func compatibleManifestStale() async throws {
        try await withTemporaryDirectory { root in
            let existing = root.appending(path: "photo.CR3")
            try Data("changed on disk".utf8).write(to: existing)
            let sourceDigest = try await digest(of: Data("the real source".utf8))
            let assessment = await ConflictClassifier().assess(
                existingFileAt: existing,
                evidence: .init(relativePath: "photo.CR3", expectedByteCount: 15, sourceChecksum: sourceDigest,
                                currentResult: nil,
                                compatibleRecord: .init(transferID: UUID(), transferName: "Yesterday",
                                                        sourceChecksum: sourceDigest, byteCount: 15)),
                fileSystem: LocalFileSystem())
            #expect(assessment.classification == .ambiguous)
        }
    }

    @Test("Unicode paths match across NFC and NFD normalisation")
    func unicodeNormalisation() async throws {
        let composed = "DCIM/caf\u{00E9}-\u{1F4F7}.jpg"
        let decomposed = "DCIM/cafe\u{0301}-\u{1F4F7}.jpg"
        let record = CompatibleManifestIndex.Record(transferID: UUID(), transferName: "Yesterday",
                                                    sourceChecksum: "abc", byteCount: 1)
        let index = CompatibleManifestIndex(records: [composed: record])
        #expect(index[decomposed]?.sourceChecksum == "abc")
        #expect(index[composed]?.sourceChecksum == "abc")
        #expect(index["DCIM/other.jpg"] == nil)
    }

    // MARK: - Durable recording and the pause

    @Test("Identical destination content is skipped and recorded durably as verified")
    func coordinatorSkipsIdenticalContent() async throws {
        try await withConflictFixture(preexisting: .identical) { plan, roots in
            let outcome = try await TransferCoordinator().execute(plan: plan)
            #expect(outcome.conflicts.isEmpty)
            #expect(outcome.state == .verified)
            #expect(outcome.destinations[0].verifiedFiles == plan.files.count)

            let manifest = try await ManifestStore().load(
                from: roots[0].appending(path: "\(plan.name)/.cardvault/transfer-manifest.json"))
            let record = try #require(manifest.files
                .first { $0.relativeDestinationPath == "DCIM/photo.CR3" }?
                .destinations[plan.destinations[0].id])
            #expect(record.copyState == .skipped)
            #expect(record.conflict == .contentIdentical)
            #expect(record.verification == .verified)
            // The skip is auditable: the digest recorded is the one read back.
            #expect(record.destinationChecksum != nil)
        }
    }

    @Test("Different content at the same path pauses instead of overwriting")
    func coordinatorPausesOnConflict() async throws {
        try await withConflictFixture(preexisting: .foreign) { plan, roots in
            let outcome = try await TransferCoordinator().execute(plan: plan)
            #expect(outcome.requiresConflictResolution)
            #expect(outcome.state == .needsAttention)
            #expect(outcome.conflicts.count == 1)
            #expect(outcome.conflicts[0].relativePath == "DCIM/photo.CR3")
            #expect(outcome.conflicts[0].classification == .unrelatedFile)
            // Resuming needs the source, so the card is not offered for ejection.
            #expect(!outcome.safeToEject)

            let staging = roots[0].appending(path: ".\(plan.name).cardvault-incomplete-\(plan.id.uuidString)")
            let existing = staging.appending(path: "Originals/DCIM/photo.CR3")
            #expect(try Data(contentsOf: existing) == Data("someone else's file".utf8))
            // Nothing was finalised and no alternative filename was invented.
            #expect(!FileManager.default.fileExists(atPath: roots[0].appending(path: plan.name).path))
            let siblings = try FileManager.default.contentsOfDirectory(
                atPath: existing.deletingLastPathComponent().path).sorted()
            #expect(siblings == ["other.jpg", "photo.CR3"])

            let manifest = try await ManifestStore().load(
                from: staging.appending(path: ".cardvault/transfer-manifest.json"))
            let record = try #require(manifest.files
                .first { $0.relativeDestinationPath == "DCIM/photo.CR3" }?
                .destinations[plan.destinations[0].id])
            #expect(record.copyState == .conflicted)
            #expect(record.conflict == .unrelatedFile)
            #expect(record.verification == .pending)
            #expect(manifest.state == .needsAttention)
            #expect(manifest.warnings.contains { $0.contains("DCIM/photo.CR3") })
        }
    }

    @Test("An unfinished artifact is retried without a conflict")
    func coordinatorReplacesIncompleteArtifact() async throws {
        try await withConflictFixture(preexisting: .none) { plan, roots in
            let injector = FaultInjector(rules: [.init(.write, pathContains: "photo.CR3")])
            let first = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector))
                .execute(plan: plan)
            #expect(!first.destinations[0].isVerified)
            let manifestURL = roots[0]
                .appending(path: ".\(plan.name).cardvault-incomplete-\(plan.id.uuidString)")
                .appending(path: ".cardvault/transfer-manifest.json")
            let resumed = try await TransferCoordinator().resume(plan: plan, manifestURL: manifestURL)
            #expect(resumed.conflicts.isEmpty)
            #expect(resumed.state == .verified)
        }
    }

    @Test("Conflicts are reported per destination and leave the other destination intact")
    func coordinatorReportsPerDestination() async throws {
        try await withConflictFixture(preexisting: .foreign, destinationCount: 2) { plan, roots in
            let outcome = try await TransferCoordinator().execute(plan: plan)
            #expect(outcome.conflicts.count == 1)
            #expect(outcome.conflicts[0].destinationID == plan.destinations[0].id)
            #expect(outcome.conflicts[0].destinationLabel == "Primary")

            let manifest = try await ManifestStore().load(
                from: roots[0].appending(path: ".\(plan.name).cardvault-incomplete-\(plan.id.uuidString)")
                    .appending(path: ".cardvault/transfer-manifest.json"))
            // The clean destination copied everything and carries no conflict.
            // Pausing before verification means nothing is verified yet anywhere,
            // which is why the backup is not reported as verified either.
            let backup = manifest.files.compactMap { $0.destinations[plan.destinations[1].id] }
            #expect(backup.count == plan.files.count)
            #expect(backup.allSatisfy { $0.copyState == .copied && $0.conflict == nil })
            #expect(outcome.destinations[1].verifiedFiles == 0)
        }
    }

    @Test("A verified sibling transfer on the same drive is recognised across manifests")
    func coordinatorUsesCompatibleManifest() async throws {
        try await withConflictFixture(preexisting: .identical, siblingTransfer: true) { plan, roots in
            let outcome = try await TransferCoordinator().execute(plan: plan)
            #expect(outcome.conflicts.isEmpty)
            let manifest = try await ManifestStore().load(
                from: roots[0].appending(path: "\(plan.name)/.cardvault/transfer-manifest.json"))
            let record = try #require(manifest.files
                .first { $0.relativeDestinationPath == "DCIM/photo.CR3" }?
                .destinations[plan.destinations[0].id])
            #expect(record.conflict == .verifiedByCompatibleManifest)
            #expect(record.copyState == .skipped)
            #expect(record.verification == .verified)
        }
    }

    @Test("A conflicted result survives a manifest round trip")
    func conflictRoundTrips() throws {
        let result = DestinationFileResult(copyState: .conflicted, verification: .pending,
                                           error: "needs a decision", conflict: .ambiguous)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DestinationFileResult.self, from: data)
        #expect(decoded == result)
        #expect(decoded.conflict == .ambiguous)
    }

    @Test("A manifest written before conflict classification still decodes")
    func decodesManifestWithoutConflictField() throws {
        let legacy = Data(#"{"copyState":"copied","verification":"verified"}"#.utf8)
        let decoded = try JSONDecoder().decode(DestinationFileResult.self, from: legacy)
        #expect(decoded.conflict == nil)
        #expect(decoded.copyState == .copied)
    }
}

// MARK: - Helpers

private func digest(of data: Data) async throws -> String {
    try await withTemporaryDirectory { root in
        let url = root.appending(path: "value")
        try data.write(to: url)
        return try await LocalFileSystem().checksum(url, expectedSize: Int64(data.count))
    }
}

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(path: "CardVaultConflictTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

private enum PreexistingContent { case none, identical, foreign }

/// Builds a source with one known file and seeds the primary destination's
/// staging tree the way an interrupted or shared drive would present it.
private func withConflictFixture<T>(preexisting: PreexistingContent,
                                    destinationCount: Int = 1,
                                    siblingTransfer: Bool = false,
                                    body: (TransferPlan, [URL]) async throws -> T) async throws -> T {
    try await withTemporaryDirectory { root in
        let manager = FileManager.default
        let source = root.appending(path: "source")
        try manager.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
        let payload = Data("the original photograph".utf8)
        try payload.write(to: source.appending(path: "DCIM/photo.CR3"))
        try Data("second".utf8).write(to: source.appending(path: "DCIM/other.jpg"))

        let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
        let destinations = (0..<destinationCount).map { root.appending(path: "destination-\($0)") }
        for destination in destinations {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let sourceIdentity = VolumeIdentity(displayName: "CARD", fileSystem: "exFAT", isRemovable: true,
                                            physicalStoreIdentifier: "source")
        let plans = destinations.enumerated().map { index, url in
            DestinationPlan(label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                            volume: VolumeIdentity(displayName: url.lastPathComponent, fileSystem: "APFS",
                                                   physicalStoreIdentifier: "disk\(index)"))
        }
        let plan = TransferPlan(name: "Conflict Transfer", mode: .preserveCard, sourceRootPath: source.path,
                                sourceVolume: sourceIdentity, files: files, destinations: plans)

        if preexisting != .none {
            let staging = destinations[0]
                .appending(path: ".\(plan.name).cardvault-incomplete-\(plan.id.uuidString)")
            let originals = staging.appending(path: "Originals/DCIM")
            try manager.createDirectory(at: originals, withIntermediateDirectories: true)
            let content = preexisting == .identical ? payload : Data("someone else's file".utf8)
            try content.write(to: originals.appending(path: "photo.CR3"))
        }
        if siblingTransfer {
            // A completed transfer already on the drive that verified the same file.
            var sibling = TransferManifest(plan: TransferPlan(name: "Yesterday", mode: .preserveCard,
                                                              sourceRootPath: source.path,
                                                              sourceVolume: sourceIdentity,
                                                              files: files, destinations: plans))
            sibling.state = .safeToEject
            let digest = try await LocalFileSystem().checksum(source.appending(path: "DCIM/photo.CR3"),
                                                              expectedSize: Int64(payload.count))
            for index in sibling.files.indices where sibling.files[index].relativeSourcePath == "DCIM/photo.CR3" {
                sibling.files[index].sourceChecksum = digest
                sibling.files[index].destinations[plans[0].id] =
                    DestinationFileResult(copyState: .copied, verification: .verified, destinationChecksum: digest)
            }
            try await ManifestStore().save(sibling, to: destinations[0]
                .appending(path: "Yesterday/.cardvault/transfer-manifest.json"))
        }
        return try await body(plan, destinations)
    }
}
