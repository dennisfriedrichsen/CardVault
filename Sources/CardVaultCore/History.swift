import Foundation

/// One destination's own result, recorded independently of every other
/// destination's. A verified primary is never allowed to stand in for a backup
/// that was not verified, so these counts are kept per destination rather than
/// collapsed into a single boolean for the transfer.
public struct HistoryDestinationResult: Codable, Sendable, Identifiable, Hashable {
    public let destinationID: UUID
    public var id: UUID { destinationID }
    public let totalFiles: Int
    public let copiedFiles: Int
    public let verifiedFiles: Int
    public let mismatchedFiles: Int
    public let failedFiles: Int
    public let conflictedFiles: Int
    /// Where this destination's copy of the authoritative manifest was written.
    /// Kept in the local index only, because the portable manifest deliberately
    /// carries no mount paths. It is never written to a log.
    public let manifestPath: String?

    public init(destinationID: UUID, totalFiles: Int, copiedFiles: Int, verifiedFiles: Int,
                mismatchedFiles: Int = 0, failedFiles: Int = 0, conflictedFiles: Int = 0,
                manifestPath: String? = nil) {
        self.destinationID = destinationID
        self.totalFiles = totalFiles
        self.copiedFiles = copiedFiles
        self.verifiedFiles = verifiedFiles
        self.mismatchedFiles = mismatchedFiles
        self.failedFiles = failedFiles
        self.conflictedFiles = conflictedFiles
        self.manifestPath = manifestPath
    }

    public init(manifest: TransferManifest, destinationID: UUID, manifestPath: String?) {
        let counts = manifest.files.reduce(into: (copied: 0, verified: 0, mismatched: 0,
                                                  failed: 0, conflicted: 0)) { totals, file in
            guard let result = file.destinations[destinationID] else { return }
            if result.copyState == .copied || result.copyState == .skipped { totals.copied += 1 }
            if result.copyState == .conflicted { totals.conflicted += 1 }
            switch result.verification {
            case .verified: totals.verified += 1
            case .mismatch: totals.mismatched += 1
            case .failed: totals.failed += 1
            case .pending: break
            }
        }
        self.init(destinationID: destinationID, totalFiles: manifest.files.count,
                  copiedFiles: counts.copied, verifiedFiles: counts.verified,
                  mismatchedFiles: counts.mismatched, failedFiles: counts.failed,
                  conflictedFiles: counts.conflicted, manifestPath: manifestPath)
    }

    /// True only when every file in the transfer was independently reread and
    /// verified at this destination.
    public var isFullyVerified: Bool { totalFiles > 0 && verifiedFiles == totalFiles }
    public var unverifiedFiles: Int { max(0, totalFiles - verifiedFiles) }
}

public struct TransferHistoryEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let date: Date
    public let source: VolumeIdentity
    public let destinations: [DestinationPlan]
    public let totalFiles: Int
    public let totalBytes: Int64
    public let mode: TransferMode
    public let finalState: TransferState
    public let warnings: [String]
    /// Per-destination results, in the order the destinations were planned.
    public let results: [HistoryDestinationResult]

    public var manifestPaths: [String] { results.compactMap(\.manifestPath) }
    public var verifiedDestinationIDs: Set<UUID> {
        Set(results.filter(\.isFullyVerified).map(\.destinationID))
    }
    /// Every destination verified every file. Anything less is reported as what
    /// it is, per destination.
    public var isFullyVerified: Bool { !results.isEmpty && results.allSatisfy(\.isFullyVerified) }

    public func result(for destinationID: UUID) -> HistoryDestinationResult? {
        results.first { $0.destinationID == destinationID }
    }

    /// `manifestPaths` is keyed by destination ID rather than ordered, so a
    /// path can never be recorded against the wrong destination.
    public init(manifest: TransferManifest, manifestPaths: [UUID: String]) {
        id = manifest.transferID
        name = manifest.transferName
        date = manifest.completedAt ?? manifest.createdAt
        source = manifest.source
        destinations = manifest.destinations
        totalFiles = manifest.files.count
        totalBytes = manifest.files.reduce(0) { $0 + $1.byteCount }
        mode = manifest.mode
        finalState = manifest.state
        warnings = manifest.warnings
        results = manifest.destinations.map { destination in
            let path = manifestPaths[destination.id]
            return HistoryDestinationResult(manifest: manifest, destinationID: destination.id,
                                            manifestPath: (path?.isEmpty == false) ? path : nil)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, date, source, destinations, totalFiles, totalBytes, mode, finalState
        case warnings, results
        // Written by builds before per-destination results existed.
        case verifiedDestinationIDs, manifestPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        date = try container.decode(Date.self, forKey: .date)
        source = try container.decode(VolumeIdentity.self, forKey: .source)
        destinations = try container.decode([DestinationPlan].self, forKey: .destinations)
        totalFiles = try container.decode(Int.self, forKey: .totalFiles)
        totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        mode = try container.decode(TransferMode.self, forKey: .mode)
        finalState = try container.decode(TransferState.self, forKey: .finalState)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        if let results = try container.decodeIfPresent([HistoryDestinationResult].self, forKey: .results) {
            self.results = results
            return
        }
        // An older index recorded only whether each destination was fully
        // verified. Nothing is invented here: a destination it did not claim as
        // verified is left at zero rather than guessed at, and the manifest on
        // the drive remains the authority either way.
        let verified = try container.decodeIfPresent(Set<UUID>.self, forKey: .verifiedDestinationIDs) ?? []
        let paths = try container.decodeIfPresent([String].self, forKey: .manifestPaths) ?? []
        let files = totalFiles
        results = destinations.enumerated().map { index, destination in
            let wasVerified = verified.contains(destination.id)
            return HistoryDestinationResult(
                destinationID: destination.id, totalFiles: files,
                copiedFiles: wasVerified ? files : 0, verifiedFiles: wasVerified ? files : 0,
                manifestPath: index < paths.count ? paths[index] : nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(date, forKey: .date)
        try container.encode(source, forKey: .source)
        try container.encode(destinations, forKey: .destinations)
        try container.encode(totalFiles, forKey: .totalFiles)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encode(mode, forKey: .mode)
        try container.encode(finalState, forKey: .finalState)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(results, forKey: .results)
    }
}

public actor TransferHistoryStore {
    private let url: URL
    private var entries: [TransferHistoryEntry]
    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder.history.decode([TransferHistoryEntry].self, from: data) { entries = value }
        else { entries = [] }
    }

    public func all() -> [TransferHistoryEntry] { entries.sorted { $0.date > $1.date } }

    public func add(_ entry: TransferHistoryEntry) throws {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        try persist()
    }

    /// Takes in entries rebuilt from manifests found on connected drives. The
    /// manifest is authoritative, so an entry rebuilt from one replaces the
    /// indexed copy rather than being discarded as a duplicate.
    @discardableResult
    public func merge(_ rebuilt: [TransferHistoryEntry]) throws -> [UUID] {
        var replaced: [UUID] = []
        for entry in rebuilt {
            if let existing = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[existing] = entry
            } else {
                entries.append(entry)
            }
            replaced.append(entry.id)
        }
        guard !replaced.isEmpty else { return [] }
        try persist()
        return replaced
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    /// The history index is written with ISO-8601 dates, so it has to be read
    /// back with them. A decoder that disagrees silently drops the whole index.
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public protocol DiskEjectionService: Sendable {
    func eject(volumeAt url: URL) async throws
}
