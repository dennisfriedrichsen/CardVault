import Foundation

public struct ManifestFile: Codable, Sendable, Identifiable {
    public var id: String { relativeSourcePath }
    public var relativeSourcePath: String
    public var relativeDestinationPath: String
    public var mediaKind: MediaKind
    public var byteCount: Int64
    public var creationDate: Date?
    public var modificationDate: Date?
    public var sourceChecksum: String?
    public var destinations: [UUID: DestinationFileResult]
}

public struct TransferManifest: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var applicationVersion: String
    public var transferID: UUID
    public var transferName: String
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var verifiedAt: Date?
    public var state: TransferState
    public var mode: TransferMode
    public var source: VolumeIdentity
    public var destinations: [DestinationPlan]
    public var files: [ManifestFile]
    public var warnings: [String]
    public var errors: [String]

    public init(plan: TransferPlan, applicationVersion: String = "1.0", now: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        self.applicationVersion = applicationVersion
        transferID = plan.id
        transferName = plan.name
        createdAt = now
        state = .awaitingConfirmation
        mode = plan.mode
        source = plan.sourceVolume
        destinations = plan.destinations
        files = plan.files.map { file in
            ManifestFile(
                relativeSourcePath: file.relativePath,
                relativeDestinationPath: file.relativePath,
                mediaKind: file.mediaKind,
                byteCount: file.byteCount,
                creationDate: file.creationDate,
                modificationDate: file.modificationDate,
                destinations: Dictionary(uniqueKeysWithValues: plan.destinations.map {
                    ($0.id, DestinationFileResult())
                })
            )
        }
        warnings = []
        errors = []
    }
}

public enum ManifestError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case noValidManifest
}

public actor ManifestStore {
    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func save(_ manifest: TransferManifest, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).new-\(UUID().uuidString)")
        let backup = url.appendingPathExtension("previous")
        try data.write(to: temporary, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            if fileManager.fileExists(atPath: backup.path) { try? fileManager.removeItem(at: backup) }
            try fileManager.copyItem(at: url, to: backup)
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    public func load(from url: URL) throws -> TransferManifest {
        do { return try decode(Data(contentsOf: url)) }
        catch {
            let backup = url.appendingPathExtension("previous")
            guard let data = try? Data(contentsOf: backup) else { throw error }
            return try decode(data)
        }
    }

    private func decode(_ data: Data) throws -> TransferManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(TransferManifest.self, from: data)
        guard manifest.schemaVersion <= TransferManifest.currentSchemaVersion else {
            throw ManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }
}
