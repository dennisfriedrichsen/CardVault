import Foundation

/// Internal tuning knobs for progress aggregation and bounded concurrency.
///
/// These are deliberately not user-facing settings. They exist so tests can pin
/// deterministic thresholds and so the values chosen from Instruments runs live
/// in one reviewable place. See `Docs/progress-performance.md`.
public struct TransferTuning: Sendable, Equatable {
    /// Minimum wall-clock time between two published UI snapshots. This is a hard
    /// cap on how often the UI can be invalidated: a drive that reports a hundred
    /// chunks in that window still produces exactly one snapshot.
    public var progressInterval: TimeInterval
    /// Sliding window used to estimate the transfer rate.
    public var rateWindow: TimeInterval
    /// Minimum spacing between retained rate samples. Bounds sample memory
    /// independently of how often the file system reports bytes.
    public var rateSampleInterval: TimeInterval
    /// Chunk size used for copy and checksum reads.
    public var chunkBytes: Int
    /// Upper bound on destinations verified at the same time. `1` keeps the
    /// strictly sequential V1 behaviour.
    public var destinationConcurrency: Int

    public init(progressInterval: TimeInterval = 0.2,
                rateWindow: TimeInterval = 5,
                rateSampleInterval: TimeInterval = 0.1,
                chunkBytes: Int = 1_048_576,
                destinationConcurrency: Int = 1) {
        self.progressInterval = progressInterval
        self.rateWindow = rateWindow
        self.rateSampleInterval = rateSampleInterval
        self.chunkBytes = chunkBytes
        self.destinationConcurrency = max(1, destinationConcurrency)
    }

    public static let `default` = TransferTuning()
}

/// A throttled snapshot of one transfer phase.
///
/// `completedBytes` and `totalBytes` count *work* bytes, not payload bytes: a
/// file that is hashed at the source and written to two destinations contributes
/// its size three times to the copy phase. That keeps the bar, the rate, and the
/// estimate consistent with the work actually being performed.
public struct TransferProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case copying, verifying, finalizing }
    public let phase: Phase
    public let completedFiles: Int
    public let totalFiles: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentRelativePath: String?
    /// Recent throughput in work bytes per second, or `nil` before enough
    /// samples exist. Always an estimate; never presented as a guarantee.
    public let bytesPerSecond: Double?
    /// Estimated seconds of work remaining in this phase, or `nil` when no rate
    /// is available yet. Always an estimate.
    public let estimatedSecondsRemaining: TimeInterval?
    public let elapsedSeconds: TimeInterval

    public init(phase: Phase, completedFiles: Int, totalFiles: Int,
                completedBytes: Int64, totalBytes: Int64, currentRelativePath: String?,
                bytesPerSecond: Double? = nil, estimatedSecondsRemaining: TimeInterval? = nil,
                elapsedSeconds: TimeInterval = 0) {
        self.phase = phase
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentRelativePath = currentRelativePath
        self.bytesPerSecond = bytesPerSecond
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.elapsedSeconds = elapsedSeconds
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// True once every work byte of the phase has been processed. A completed
    /// copy phase says nothing about verification, so callers must not treat
    /// this as success.
    public var isPhaseComplete: Bool { totalBytes > 0 && completedBytes >= totalBytes }
}

/// Accumulates precise byte counters and releases throttled UI snapshots.
///
/// The aggregator is a value type driven entirely by injected timestamps, so its
/// behaviour is deterministic under test. One aggregator covers exactly one
/// phase: copy and verification progress never share counters, rate samples, or
/// throttling state.
public struct ProgressAggregator: Sendable {
    private struct Sample: Sendable {
        var time: Date
        var bytes: Int64
    }

    public let phase: TransferProgress.Phase
    public let totalFiles: Int
    public let totalBytes: Int64

    private let tuning: TransferTuning
    private let startedAt: Date
    /// Samples spaced at least `rateSampleInterval` apart, plus the most recent
    /// observation. Committed samples bound memory; `latest` keeps the estimate
    /// current between them.
    private var committed: [Sample]
    private var latest: Sample
    private var completedBytes: Int64 = 0
    private var completedFiles: Int = 0
    private var currentRelativePath: String?
    private var lastEmitTime: Date?

    public init(phase: TransferProgress.Phase, totalFiles: Int, totalBytes: Int64,
                tuning: TransferTuning = .default, startedAt: Date) {
        self.phase = phase
        self.totalFiles = totalFiles
        self.totalBytes = max(0, totalBytes)
        self.tuning = tuning
        self.startedAt = startedAt
        self.committed = [Sample(time: startedAt, bytes: 0)]
        self.latest = Sample(time: startedAt, bytes: 0)
    }

    /// Records `delta` processed bytes. Returns a snapshot only when a
    /// throttling threshold has been reached.
    public mutating func record(bytes delta: Int64, at time: Date) -> TransferProgress? {
        completedBytes += max(0, delta)
        addSample(at: time)
        return emitIfDue(at: time)
    }

    /// Records the file the phase is working on. Cheap; never forces a snapshot.
    public mutating func beginFile(_ relativePath: String?, at time: Date) -> TransferProgress? {
        currentRelativePath = relativePath
        return emitIfDue(at: time)
    }

    /// Records that one more file finished this phase.
    public mutating func completeFile(at time: Date) -> TransferProgress? {
        completedFiles = min(totalFiles, completedFiles + 1)
        return emitIfDue(at: time)
    }

    /// Releases a snapshot regardless of throttling. Used at phase boundaries so
    /// the last state of a phase is always published.
    public mutating func flush(at time: Date, currentRelativePath: String?? = nil) -> TransferProgress {
        if case let .some(path) = currentRelativePath { self.currentRelativePath = path }
        return emit(at: time)
    }

    /// Recent throughput estimate in bytes per second, or `nil` when unknown.
    public var bytesPerSecond: Double? {
        guard let first = committed.first else { return nil }
        let interval = latest.time.timeIntervalSince(first.time)
        let bytes = latest.bytes - first.bytes
        // A window shorter than one sampling interval is noise: a single fast
        // chunk would otherwise be published as a multi-gigabyte-per-second rate.
        guard interval >= tuning.rateSampleInterval, bytes > 0 else { return nil }
        return Double(bytes) / interval
    }

    private mutating func addSample(at time: Date) {
        latest = Sample(time: time, bytes: completedBytes)
        // Committing is measured against the last committed sample, never against
        // the latest observation, so frequent updates cannot starve the window.
        if let last = committed.last, time.timeIntervalSince(last.time) >= tuning.rateSampleInterval {
            committed.append(latest)
        }
        while committed.count > 1, time.timeIntervalSince(committed[0].time) > tuning.rateWindow {
            committed.removeFirst()
        }
    }

    private mutating func emitIfDue(at time: Date) -> TransferProgress? {
        guard let lastEmitTime else { return emit(at: time) }
        guard time.timeIntervalSince(lastEmitTime) >= tuning.progressInterval else { return nil }
        return emit(at: time)
    }

    private mutating func emit(at time: Date) -> TransferProgress {
        lastEmitTime = time
        let rate = bytesPerSecond
        let remaining = max(0, totalBytes - completedBytes)
        var estimate: TimeInterval?
        if remaining == 0 {
            estimate = 0
        } else if let rate, rate > 0 {
            estimate = Double(remaining) / rate
        }
        return TransferProgress(phase: phase, completedFiles: completedFiles, totalFiles: totalFiles,
                                completedBytes: completedBytes, totalBytes: totalBytes,
                                currentRelativePath: currentRelativePath,
                                bytesPerSecond: rate, estimatedSecondsRemaining: estimate,
                                elapsedSeconds: time.timeIntervalSince(startedAt))
    }
}
