import Foundation
import Testing
@testable import CardVaultCore

@Suite("Progress aggregation and performance reporting")
struct ProgressTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func aggregator(totalBytes: Int64 = 1_000, totalFiles: Int = 1,
                            tuning: TransferTuning = TransferTuning(progressInterval: 1, rateWindow: 10,
                                                                    rateSampleInterval: 0.5)) -> ProgressAggregator {
        ProgressAggregator(phase: .copying, totalFiles: totalFiles, totalBytes: totalBytes,
                           tuning: tuning, startedAt: origin)
    }

    @Test("The first update publishes immediately and later updates are throttled by time")
    func timeThrottling() {
        var aggregator = aggregator()
        #expect(aggregator.record(bytes: 100, at: origin) != nil)
        #expect(aggregator.record(bytes: 100, at: origin.addingTimeInterval(0.4)) == nil)
        #expect(aggregator.record(bytes: 100, at: origin.addingTimeInterval(0.9)) == nil)
        let due = aggregator.record(bytes: 100, at: origin.addingTimeInterval(1.0))
        #expect(due?.completedBytes == 400)
    }

    @Test("The publication rate is capped no matter how often bytes are reported")
    func publicationRateIsCapped() {
        var aggregator = aggregator(totalBytes: 10_000,
                                    tuning: TransferTuning(progressInterval: 0.2, rateWindow: 10,
                                                           rateSampleInterval: 0.5))
        var published = 0
        // Ten thousand chunk reports spread across one second of transfer.
        for step in 0..<10_000 {
            let time = origin.addingTimeInterval(Double(step) / 10_000)
            if aggregator.record(bytes: 1, at: time) != nil { published += 1 }
        }
        // One immediate snapshot plus one per elapsed 0.2 second window.
        #expect(published == 5)
        #expect(aggregator.flush(at: origin.addingTimeInterval(1)).completedBytes == 10_000)
    }

    @Test("File boundaries and paths do not defeat throttling")
    func fileBoundariesAreThrottled() {
        var aggregator = aggregator(totalFiles: 3)
        _ = aggregator.record(bytes: 10, at: origin)
        #expect(aggregator.beginFile("DCIM/a.jpg", at: origin.addingTimeInterval(0.1)) == nil)
        #expect(aggregator.completeFile(at: origin.addingTimeInterval(0.2)) == nil)
        let snapshot = aggregator.flush(at: origin.addingTimeInterval(0.3))
        #expect(snapshot.completedFiles == 1)
        #expect(snapshot.currentRelativePath == "DCIM/a.jpg")
    }

    @Test("Rate and remaining time are derived from the sampling window")
    func rateAndEstimate() {
        var aggregator = aggregator()
        let first = aggregator.record(bytes: 100, at: origin)
        #expect(first?.bytesPerSecond == nil)
        #expect(first?.estimatedSecondsRemaining == nil)

        // 200 bytes in one second since the phase started.
        let second = aggregator.record(bytes: 100, at: origin.addingTimeInterval(1))
        #expect(second?.bytesPerSecond == 200)
        // 800 bytes remain of 1_000 at 200 bytes per second.
        #expect(second?.estimatedSecondsRemaining == 4)
    }

    @Test("A stale fast start does not inflate the estimate forever")
    func slidingWindow() {
        var aggregator = aggregator(totalBytes: 100_000,
                                    tuning: TransferTuning(progressInterval: 0, rateWindow: 2,
                                                           rateSampleInterval: 0.5))
        _ = aggregator.record(bytes: 10_000, at: origin)
        _ = aggregator.record(bytes: 10_000, at: origin.addingTimeInterval(1))
        #expect(aggregator.bytesPerSecond == 20_000)
        // The drive slows to 10 bytes per second; the window must forget the burst.
        for step in 2...8 {
            _ = aggregator.record(bytes: 10, at: origin.addingTimeInterval(Double(step)))
        }
        let rate = try? #require(aggregator.bytesPerSecond)
        #expect(rate.map { $0 <= 20 } == true)
    }

    @Test("A finished phase publishes a complete snapshot with no time remaining")
    func flushCompletesPhase() {
        var aggregator = aggregator()
        _ = aggregator.record(bytes: 1_000, at: origin)
        let snapshot = aggregator.flush(at: origin.addingTimeInterval(0.01), currentRelativePath: .some(nil))
        #expect(snapshot.isPhaseComplete)
        #expect(snapshot.fractionCompleted == 1)
        #expect(snapshot.estimatedSecondsRemaining == 0)
        #expect(snapshot.currentRelativePath == nil)
    }

    @Test("A completed copy phase is never reported as verified")
    func copyCompletionIsNotSuccess() async throws {
        try await withProgressFixture(destinationCount: 1) { plan, roots in
            // Verification reads fail, so every copy still finishes at 100 percent.
            let injector = FaultInjector(rules: [.init(.read, pathContains: roots[0].lastPathComponent)])
            let recorder = SnapshotRecorder()
            let outcome = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector))
                .execute(plan: plan) { await recorder.append($0) }

            let snapshots = await recorder.snapshots
            let copies = snapshots.filter { $0.phase == .copying }
            let verifications = snapshots.filter { $0.phase == .verifying }
            #expect(copies.last?.isPhaseComplete == true)
            #expect(!verifications.isEmpty)
            #expect(outcome.state == .failed)
            #expect(outcome.destinations.allSatisfy { !$0.isVerified })
        }
    }

    @Test("Copy progress is fully published before verification progress begins")
    func phasesStayIndependent() async throws {
        try await withProgressFixture(destinationCount: 2) { plan, _ in
            let recorder = SnapshotRecorder()
            let outcome = try await TransferCoordinator(fileSystem: LocalFileSystem(chunkBytes: 4_096))
                .execute(plan: plan) { await recorder.append($0) }

            let snapshots = await recorder.snapshots
            let lastCopy = try #require(snapshots.lastIndex { $0.phase == .copying })
            let firstVerification = try #require(snapshots.firstIndex { $0.phase == .verifying })
            #expect(lastCopy < firstVerification)
            #expect(snapshots[lastCopy].isPhaseComplete)
            #expect(snapshots[lastCopy].completedFiles == plan.files.count)
            // Copy hashes the source once and writes it to each destination.
            #expect(snapshots[lastCopy].totalBytes == plan.totalBytes * 3)
            #expect(snapshots[firstVerification].completedBytes < snapshots[firstVerification].totalBytes)
            #expect(outcome.state == .verified)
        }
    }

    @Test("Byte updates are aggregated instead of forwarded one chunk at a time")
    func chunkUpdatesAreAggregated() async throws {
        try await withProgressFixture(destinationCount: 1) { plan, _ in
            // A frozen clock means only threshold-crossing and phase-boundary
            // snapshots are published, however many chunks the copy reads.
            let recorder = SnapshotRecorder()
            let frozen = Date(timeIntervalSince1970: 1_700_000_000)
            let coordinator = TransferCoordinator(fileSystem: LocalFileSystem(chunkBytes: 4_096),
                                                  tuning: TransferTuning(progressInterval: 0.2, chunkBytes: 4_096),
                                                  now: { frozen })
            _ = try await coordinator.execute(plan: plan) { await recorder.append($0) }

            let snapshots = await recorder.snapshots
            // The fixture reads well over 700 chunks; three phases publish twice each.
            #expect(snapshots.count == 6)
            #expect(snapshots.filter { $0.phase == .copying }.count == 2)
            #expect(snapshots.filter { $0.phase == .verifying }.count == 2)
            #expect(snapshots.filter { $0.phase == .finalizing }.count == 2)
        }
    }

    @Test("Bounded destination concurrency preserves verification results")
    func boundedConcurrencyMatchesSequential() async throws {
        try await withProgressFixture(destinationCount: 2) { plan, _ in
            let recorder = SnapshotRecorder()
            let outcome = try await TransferCoordinator(tuning: TransferTuning(destinationConcurrency: 2))
                .execute(plan: plan) { await recorder.append($0) }

            #expect(outcome.state == .verified)
            #expect(outcome.destinations.allSatisfy { $0.verifiedFiles == plan.files.count })
            let verifications = await recorder.snapshots.filter { $0.phase == .verifying }
            #expect(verifications.last?.isPhaseComplete == true)
            #expect(verifications.last?.totalBytes == plan.totalBytes * 2)
        }
    }

    @Test("Bounded concurrency keeps independent per-destination outcomes")
    func boundedConcurrencyKeepsIndependentOutcomes() async throws {
        try await withProgressFixture(destinationCount: 2) { plan, roots in
            let injector = FaultInjector(rules: [.init(.write, pathContains: roots[1].lastPathComponent)])
            let outcome = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector),
                                                        tuning: TransferTuning(destinationConcurrency: 2))
                .execute(plan: plan)
            #expect(outcome.state == .partiallySuccessful)
            #expect(outcome.destinations[0].isVerified)
            #expect(!outcome.destinations[1].isVerified)
        }
    }
}

private actor SnapshotRecorder {
    private(set) var snapshots: [TransferProgress] = []
    func append(_ snapshot: TransferProgress) { snapshots.append(snapshot) }
}

private func withProgressFixture<T>(destinationCount: Int,
                                    body: (TransferPlan, [URL]) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appending(path: "CardVaultProgressTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source")
    try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
    try Data("photo".utf8).write(to: source.appending(path: "DCIM/photo.CR3"))
    try Data(repeating: 7, count: 1_500_000).write(to: source.appending(path: "DCIM/large.mov"))
    let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
    let destinations = (0..<destinationCount).map { root.appending(path: "destination-\($0)") }
    for destination in destinations {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    let destinationPlans = destinations.enumerated().map { index, url in
        DestinationPlan(label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                        volume: VolumeIdentity(displayName: url.lastPathComponent, fileSystem: "APFS",
                                               physicalStoreIdentifier: "disk\(index)"))
    }
    let plan = TransferPlan(name: "Progress Transfer", mode: .preserveCard, sourceRootPath: source.path,
                            sourceVolume: VolumeIdentity(displayName: "CARD", fileSystem: "exFAT",
                                                         isRemovable: true, physicalStoreIdentifier: "source"),
                            files: files, destinations: destinationPlans)
    return try await body(plan, destinations)
}
