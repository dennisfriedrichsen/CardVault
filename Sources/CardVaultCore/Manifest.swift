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
    /// Set when the user explicitly abandoned the transfer. The record and every
    /// verified file it describes stay on disk; this only stops recovery from
    /// offering the transfer again. Additive, so `schemaVersion` stays 1.
    public var abandonedAt: Date?
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
        abandonedAt = nil
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
    /// A version this build never wrote, so the document cannot be read as v1.
    case invalidSchema(Int)
    /// A path in the record could reach outside the transfer's own tree.
    case unsafePath(String)
    case noValidManifest
}

public actor ManifestStore {
    /// Consulted before every save. Returning an error keeps the record off the
    /// disk, which is how a disconnected drive — or a process that dies between
    /// two manifest updates — looks to everything above this store.
    public typealias SaveInterceptor = @Sendable (TransferManifest, URL) async -> Error?

    private let fileManager: FileManager
    private let interceptor: SaveInterceptor?

    public init(fileManager: FileManager = .default, beforeSave: SaveInterceptor? = nil) {
        self.fileManager = fileManager
        interceptor = beforeSave
    }

    public func save(_ manifest: TransferManifest, to url: URL) async throws {
        if let error = await interceptor?(manifest, url) { throw error }
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
        // Bounded below as well: a zero or negative version is not v1 written by
        // an older build, it is a document this build has no reason to trust.
        guard manifest.schemaVersion >= 1 else { throw ManifestError.invalidSchema(manifest.schemaVersion) }
        try Self.validatePaths(in: manifest)
        return manifest
    }

    /// The manifest lives on removable media and is writable by anything with
    /// access to the drive, while the paths in it are joined onto a destination
    /// root and then deleted and written. They are checked once, here, so that
    /// no caller can be the one that forgot — and a record that fails is
    /// reported as unreadable rather than acted on.
    static func validatePaths(in manifest: TransferManifest) throws {
        for file in manifest.files {
            try validate(path: file.relativeSourcePath)
            try validate(path: file.relativeDestinationPath)
        }
    }

    private static func validate(path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw ManifestError.unsafePath(path)
        }
    }
}
