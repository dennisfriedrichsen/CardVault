import Foundation

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
    public let verifiedDestinationIDs: Set<UUID>
    public let warnings: [String]
    public let manifestPaths: [String]

    public init(manifest: TransferManifest, manifestPaths: [String]) {
        id = manifest.transferID
        name = manifest.transferName
        date = manifest.completedAt ?? manifest.createdAt
        source = manifest.source
        destinations = manifest.destinations
        totalFiles = manifest.files.count
        totalBytes = manifest.files.reduce(0) { $0 + $1.byteCount }
        mode = manifest.mode
        finalState = manifest.state
        verifiedDestinationIDs = Set(manifest.destinations.compactMap { destination in
            manifest.files.allSatisfy { $0.destinations[destination.id]?.verification == .verified } ? destination.id : nil
        })
        warnings = manifest.warnings
        self.manifestPaths = manifestPaths
    }
}

public actor TransferHistoryStore {
    private let url: URL
    private var entries: [TransferHistoryEntry]
    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let value = try? JSONDecoder().decode([TransferHistoryEntry].self, from: data) { entries = value }
        else { entries = [] }
    }

    public func all() -> [TransferHistoryEntry] { entries.sorted { $0.date > $1.date } }
    public func add(_ entry: TransferHistoryEntry) throws {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

public protocol DiskEjectionService: Sendable {
    func eject(volumeAt url: URL) async throws
}
