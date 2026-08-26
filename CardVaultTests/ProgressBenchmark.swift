#if CARDVAULT_BENCHMARK
import Foundation
import Testing
@testable import CardVaultCore

/// Not part of the normal suite. Run with:
/// `swift test -Xswiftc -DCARDVAULT_BENCHMARK --filter ProgressBenchmark`
/// and record the printed lines in `Docs/progress-performance.md`.
@Suite("Progress publication benchmark", .serialized)
struct ProgressBenchmark {
    @Test("Measure published snapshots per gigabyte")
    func measure() async throws {
        try await run(label: "single-destination", destinationCount: 1, tuning: .default)
    }

    @Test("Measure sequential and bounded-concurrency verification")
    func measureConcurrency() async throws {
        try await run(label: "dual-sequential", destinationCount: 2, tuning: TransferTuning(destinationConcurrency: 1))
        try await run(label: "dual-concurrent", destinationCount: 2, tuning: TransferTuning(destinationConcurrency: 2))
    }

    private func run(label: String, destinationCount: Int, tuning: TransferTuning) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CardVaultBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "source/DCIM"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = Data(repeating: 9, count: 8 * 1_048_576)
        for index in 0..<16 {
            let url = root.appending(path: "source/DCIM/clip-\(index).mov")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            for _ in 0..<4 { try handle.write(contentsOf: chunk) }
            try handle.close()
        }
        let files = try SourceScanner().scan(root: root.appending(path: "source"), mode: .preserveCard).files
        let destinations = (0..<destinationCount).map { root.appending(path: "destination-\($0)") }
        for destination in destinations {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        let plan = TransferPlan(name: "Bench", mode: .preserveCard,
                                sourceRootPath: root.appending(path: "source").path,
                                sourceVolume: VolumeIdentity(displayName: "CARD", isRemovable: true),
                                files: files,
                                destinations: destinations.enumerated().map { index, url in
                                    DestinationPlan(label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                                                    volume: VolumeIdentity(displayName: url.lastPathComponent,
                                                                           physicalStoreIdentifier: "disk\(index)"))
                                })
        let counter = Counter()
        let start = Date()
        let outcome = try await TransferCoordinator(tuning: tuning).execute(plan: plan) { await counter.record($0) }
        let elapsed = Date().timeIntervalSince(start)
        let count = await counter.count
        let peak = await counter.peakRate
        let gigabytes = Double(plan.totalBytes) / 1_073_741_824
        print("BENCH \(label) state=\(outcome.state) bytes=\(plan.totalBytes) elapsed=\(String(format: "%.2f", elapsed))s snapshots=\(count) perGB=\(String(format: "%.0f", Double(count) / gigabytes)) perSecond=\(String(format: "%.1f", Double(count) / elapsed)) withRate=\(await counter.withRate) peakReportedRate=\(String(format: "%.0f", peak / 1_048_576))MBps")
    }
}

private actor Counter {
    private(set) var count = 0
    private(set) var peakRate: Double = 0
    private(set) var withRate = 0
    func record(_ snapshot: TransferProgress) {
        count += 1
        peakRate = max(peakRate, snapshot.bytesPerSecond ?? 0)
        if snapshot.bytesPerSecond != nil { withRate += 1 }
    }
}
#endif
