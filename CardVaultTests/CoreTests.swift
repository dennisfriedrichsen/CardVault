import CryptoKit
import Foundation
import Testing
@testable import CardVaultCore

@Suite("CardVault reliability core")
struct CoreTests {
    @Test("State machine accepts valid transitions")
    func stateMachineValid() throws {
        var machine = TransferStateMachine()
        try machine.transition(to: .scanning)
        try machine.transition(to: .ready)
        try machine.transition(to: .preflighting)
        try machine.transition(to: .awaitingConfirmation)
        try machine.transition(to: .copying)
        try machine.transition(to: .copyComplete)
        try machine.transition(to: .verifying)
        try machine.transition(to: .verified)
        try machine.transition(to: .safeToEject)
        #expect(machine.state == .safeToEject)
    }

    @Test("State machine rejects verification before copying")
    func stateMachineInvalid() {
        var machine = TransferStateMachine(state: .ready)
        #expect(throws: TransferStateError.invalidTransition(from: .ready, to: .verified)) {
            try machine.transition(to: .verified)
        }
    }

    @Test("Manifest round trips human-readable JSON and ISO dates")
    func manifestRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let plan = makePlan(source: root, destinations: [root.appending(path: "destination")], files: [])
            let manifest = TransferManifest(plan: plan, now: Date(timeIntervalSince1970: 1_700_000_000))
            let url = root.appending(path: "manifest.json")
            let store = ManifestStore()
            try await store.save(manifest, to: url)
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("\"schemaVersion\" : 1"))
            #expect(text.contains("2023-11"))
            #expect(!text.contains(root.path))
            let loaded = try await store.load(from: url)
            #expect(loaded.transferID == plan.id)
        }
    }

    @Test("Manifest rejects a future schema")
    func futureSchema() async throws {
        try await withTemporaryDirectory { root in
            var manifest = TransferManifest(plan: makePlan(source: root, destinations: [], files: []))
            manifest.schemaVersion = 999
            let url = root.appending(path: "future.json")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: url)
            await #expect(throws: ManifestError.unsupportedSchema(999)) {
                try await ManifestStore().load(from: url)
            }
        }
    }

    @Test("Damaged current manifest recovers the previous valid update")
    func manifestRecovery() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appending(path: "manifest.json")
            let store = ManifestStore()
            var first = TransferManifest(plan: makePlan(source: root, destinations: [], files: []))
            try await store.save(first, to: url)
            first.state = .copying
            try await store.save(first, to: url)
            try Data("damage".utf8).write(to: url)
            let recovered = try await store.load(from: url)
            #expect(recovered.state == .awaitingConfirmation)
        }
    }

    @Test("Scanner preserves paths, classifies media, and counts physical RAW/JPEG files")
    func scanMedia() throws {
        try withTemporaryDirectorySync { root in
            let dcim = root.appending(path: "DCIM/100CANON")
            try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
            try Data([1]).write(to: dcim.appending(path: "IMG_0001.CR3"))
            try Data([2]).write(to: dcim.appending(path: "IMG_0001.JPG"))
            try Data().write(to: dcim.appending(path: "notes.txt"))
            try Data([3]).write(to: dcim.appending(path: "日本.mov"))
            let result = try SourceScanner().scan(root: root, mode: .mediaOnly)
            #expect(result.files.count == 3)
            #expect(result.excludedFiles.count == 1)
            #expect(result.rawJPEGPairCount == 1)
            #expect(result.files.contains { $0.relativePath == "DCIM/100CANON/日本.mov" })
        }
    }

    @Test("Preflight prevents selecting a destination inside the source")
    func destinationInsideSource() throws {
        try withTemporaryDirectorySync { root in
            let destination = root.appending(path: "bad")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let plan = makePlan(source: root, destinations: [destination], files: [])
            let result = TransferPreflightService(safetyMarginBytes: 0).validate(plan)
            #expect(result.issues.contains { $0.code == "destination-in-source" && $0.severity == .blocking })
        }
    }

    @Test("Preflight warns when both copies share one physical device")
    func sameDeviceWarning() throws {
        try withTemporaryDirectorySync { root in
            let primary = root.deletingLastPathComponent().appending(path: UUID().uuidString)
            let backup = root.deletingLastPathComponent().appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: primary); try? FileManager.default.removeItem(at: backup) }
            var plan = makePlan(source: root, destinations: [primary, backup], files: [])
            for index in plan.destinations.indices { plan.destinations[index].volume.physicalStoreIdentifier = "disk1" }
            let result = TransferPreflightService(safetyMarginBytes: 0).validate(plan)
            #expect(result.issues.contains { $0.code == "same-device" && $0.severity == .warning })
        }
    }

    @Test("Case-folding collisions block case-insensitive destinations")
    func caseCollision() throws {
        try withTemporaryDirectorySync { root in
            let destination = root.deletingLastPathComponent().appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: destination) }
            let files = [SourceFile(relativePath: "A.JPG", byteCount: 1, mediaKind: .jpeg),
                         SourceFile(relativePath: "a.jpg", byteCount: 1, mediaKind: .jpeg)]
            let plan = makePlan(source: root, destinations: [destination], files: files)
            let result = TransferPreflightService(safetyMarginBytes: 0).validate(plan)
            #expect(result.issues.contains { $0.code == "case-collision" })
        }
    }

    @Test("exFAT-incompatible filenames are blocked")
    func exFATName() throws {
        try withTemporaryDirectorySync { root in
            let destination = root.deletingLastPathComponent().appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: destination) }
            let files = [SourceFile(relativePath: "DCIM/bad:name.jpg", byteCount: 1, mediaKind: .jpeg)]
            var plan = makePlan(source: root, destinations: [destination], files: files)
            plan.destinations[0].volume.fileSystem = "exFAT"
            let result = TransferPreflightService(safetyMarginBytes: 0).validate(plan)
            #expect(result.issues.contains { $0.code == "exfat-name" })
        }
    }

    @Test("SHA-256 matches the standard digest")
    func sha256() async throws {
        try await withTemporaryDirectory { root in
            let file = root.appending(path: "value")
            try Data("abc".utf8).write(to: file)
            let digest = try await LocalFileSystem().checksum(file, expectedSize: 3)
            #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
    }

    @Test("Single destination copies and independently verifies every file")
    func singleDestination() async throws {
        try await withTransferFixture(destinationCount: 1) { plan, _ in
            let outcome = try await TransferCoordinator().execute(plan: plan)
            #expect(outcome.state == .verified)
            #expect(outcome.safeToEject)
            #expect(outcome.destinations.first?.verifiedFiles == 3)
            #expect(outcome.destinations.first?.finalURL.map { FileManager.default.fileExists(atPath: $0.appending(path: "Originals/DCIM/zero.jpg").path) } == true)
        }
    }

    @Test("Dual destinations have independent successful verification")
    func dualDestination() async throws {
        try await withTransferFixture(destinationCount: 2) { plan, _ in
            let outcome = try await TransferCoordinator().execute(plan: plan)
            #expect(outcome.destinations.count == 2)
            #expect(outcome.destinations.allSatisfy { $0.isVerified })
        }
    }

    @Test("Primary success remains visible when backup writing fails")
    func backupFailure() async throws {
        try await withTransferFixture(destinationCount: 2) { plan, roots in
            let injector = FaultInjector(rules: [.init(.write, pathContains: roots[1].lastPathComponent)])
            let outcome = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector)).execute(plan: plan)
            #expect(outcome.state == .partiallySuccessful)
            #expect(outcome.destinations[0].isVerified)
            #expect(!outcome.destinations[1].isVerified)
            #expect(outcome.safeToEject)
        }
    }

    @Test("Backup success remains visible when primary writing fails")
    func primaryFailure() async throws {
        try await withTransferFixture(destinationCount: 2) { plan, roots in
            let injector = FaultInjector(rules: [.init(.write, pathContains: roots[0].lastPathComponent)])
            let outcome = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector)).execute(plan: plan)
            #expect(!outcome.destinations[0].isVerified)
            #expect(outcome.destinations[1].isVerified)
            #expect(outcome.state == .partiallySuccessful)
        }
    }

    @Test("An interrupted file is retried at its boundary without overwriting verified files")
    func resumeAtFileBoundary() async throws {
        try await withTransferFixture(destinationCount: 1) { plan, roots in
            let injector = FaultInjector(rules: [.init(.write, pathContains: "zero.jpg")])
            let first = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector)).execute(plan: plan)
            #expect(!first.destinations[0].isVerified)
            let staging = roots[0].appending(path: ".\(plan.name).cardvault-incomplete-\(plan.id.uuidString)")
            let manifestURL = staging.appending(path: ".cardvault/transfer-manifest.json")
            let resumed = try await TransferCoordinator().resume(plan: plan, manifestURL: manifestURL)
            #expect(resumed.state == .verified)
            #expect(resumed.destinations[0].verifiedFiles == plan.files.count)
        }
    }

    @Test("Existing final destination is never overwritten")
    func existingConflict() async throws {
        try await withTransferFixture(destinationCount: 1) { plan, roots in
            try FileManager.default.createDirectory(at: roots[0].appending(path: plan.name), withIntermediateDirectories: true)
            await #expect(throws: FileSystemError.existingConflict(roots[0].appending(path: plan.name).path)) {
                try await TransferCoordinator().execute(plan: plan)
            }
        }
    }
}

private func makePlan(source: URL, destinations: [URL], files: [SourceFile]) -> TransferPlan {
    let sourceIdentity = VolumeIdentity(displayName: "CARD", fileSystem: "exFAT", isRemovable: true,
                                        physicalStoreIdentifier: "source")
    let destinationPlans = destinations.enumerated().map { index, url in
        DestinationPlan(label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                        volume: VolumeIdentity(displayName: url.lastPathComponent, fileSystem: "APFS",
                                               physicalStoreIdentifier: "disk\(index)"))
    }
    return TransferPlan(name: "Test Transfer", mode: .preserveCard, sourceRootPath: source.path,
                        sourceVolume: sourceIdentity, files: files, destinations: destinationPlans)
}

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(path: "CardVaultTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

private func withTemporaryDirectorySync<T>(_ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appending(path: "CardVaultTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

private func withTransferFixture<T>(destinationCount: Int,
                                    body: (TransferPlan, [URL]) async throws -> T) async throws -> T {
    try await withTemporaryDirectory { root in
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: source.appending(path: "DCIM/photo.CR3"))
        try Data().write(to: source.appending(path: "DCIM/zero.jpg"))
        try Data(repeating: 7, count: 1_500_000).write(to: source.appending(path: "DCIM/large.mov"))
        let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
        let destinations = (0..<destinationCount).map { root.appending(path: "destination-\($0)") }
        for destination in destinations { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        return try await body(makePlan(source: source, destinations: destinations, files: files), destinations)
    }
}
