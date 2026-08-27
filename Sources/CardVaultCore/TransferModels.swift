import Foundation

public enum TransferMode: String, Codable, CaseIterable, Sendable {
    case preserveCard
    case mediaOnly
    case customDestination

    public var title: String {
        switch self {
        case .preserveCard: "Preserve Card"
        case .mediaOnly: "Media Only"
        case .customDestination: "Custom Destination"
        }
    }
}

/// What a file is *for*, which is what a summary should report. A card may hold
/// only video, only JPEG, or a mix; nothing here assumes a stills workflow.
public enum MediaCategory: String, Codable, Sendable, CaseIterable {
    case photo, video, audio, sidecar, other

    public var title: String {
        switch self {
        case .photo: "Photos"
        case .video: "Videos"
        case .audio: "Audio"
        case .sidecar: "Sidecars"
        case .other: "Other files"
        }
    }
}

public enum MediaKind: String, Codable, Sendable {
    case raw, jpeg, heif, tiff, png, video, audio, sidecar, other

    public var category: MediaCategory {
        switch self {
        case .raw, .jpeg, .heif, .tiff, .png: .photo
        case .video: .video
        case .audio: .audio
        case .sidecar: .sidecar
        case .other: .other
        }
    }

    /// Sidecars count as media: a proxy or per-clip metadata file left behind is
    /// a loss the camera cannot regenerate.
    public var isRecognizedMedia: Bool { self != .other }
}

public enum TransferState: String, Codable, CaseIterable, Sendable {
    case discoveringSource, scanning, ready, preflighting, awaitingConfirmation
    case copying, copyComplete, verifying, verified, interrupted, needsAttention
    case partiallySuccessful, failed, cancelled, safeToEject
}

public enum TransferStateError: Error, Equatable, Sendable {
    case invalidTransition(from: TransferState, to: TransferState)
}

public struct TransferStateMachine: Sendable {
    public private(set) var state: TransferState

    public init(state: TransferState = .discoveringSource) { self.state = state }

    public mutating func transition(to next: TransferState) throws {
        guard Self.validTransitions[state, default: []].contains(next) else {
            throw TransferStateError.invalidTransition(from: state, to: next)
        }
        state = next
    }

    public static let validTransitions: [TransferState: Set<TransferState>] = [
        .discoveringSource: [.scanning, .needsAttention, .cancelled],
        .scanning: [.ready, .interrupted, .failed, .cancelled],
        .ready: [.preflighting, .scanning, .cancelled],
        .preflighting: [.awaitingConfirmation, .needsAttention, .failed, .cancelled],
        .awaitingConfirmation: [.copying, .ready, .cancelled],
        .copying: [.copyComplete, .interrupted, .needsAttention, .failed, .cancelled],
        .copyComplete: [.verifying, .interrupted, .failed],
        .verifying: [.verified, .partiallySuccessful, .interrupted, .needsAttention, .failed, .cancelled],
        .verified: [.safeToEject],
        .partiallySuccessful: [.safeToEject, .copying, .verifying],
        .interrupted: [.copying, .verifying, .needsAttention, .cancelled],
        .needsAttention: [.copying, .verifying, .cancelled, .failed],
        .failed: [.safeToEject],
        .cancelled: [.safeToEject],
        .safeToEject: []
    ]
}

public struct VolumeIdentity: Codable, Hashable, Sendable {
    public var volumeUUID: UUID?
    public var resourceIdentifier: String?
    public var displayName: String
    public var fileSystem: String
    public var isRemovable: Bool
    public var isLocal: Bool
    /// Whole physical device the volume lives on, e.g. `disk4`. Only comparable across identities
    /// resolved from Disk Arbitration.
    public var physicalStoreIdentifier: String?
    /// Partition backing the volume, e.g. `disk4s1`.
    public var partitionIdentifier: String?
    public var identitySource: VolumeIdentitySource?

    public init(volumeUUID: UUID? = nil, resourceIdentifier: String? = nil,
                displayName: String, fileSystem: String = "Unknown",
                isRemovable: Bool = false, isLocal: Bool = true,
                physicalStoreIdentifier: String? = nil,
                partitionIdentifier: String? = nil,
                identitySource: VolumeIdentitySource? = nil) {
        self.volumeUUID = volumeUUID
        self.resourceIdentifier = resourceIdentifier
        self.displayName = displayName
        self.fileSystem = fileSystem
        self.isRemovable = isRemovable
        self.isLocal = isLocal
        self.physicalStoreIdentifier = physicalStoreIdentifier
        self.partitionIdentifier = partitionIdentifier
        self.identitySource = identitySource
    }
}

public struct SourceFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let byteCount: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
    public let mediaKind: MediaKind

    public init(relativePath: String, byteCount: Int64, creationDate: Date? = nil,
                modificationDate: Date? = nil, mediaKind: MediaKind) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.mediaKind = mediaKind
    }
}

public struct DestinationPlan: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public var rootPath: String
    public var volume: VolumeIdentity

    public init(id: UUID = UUID(), label: String, rootPath: String, volume: VolumeIdentity) {
        self.id = id
        self.label = label
        self.rootPath = rootPath
        self.volume = volume
    }

    private enum CodingKeys: String, CodingKey { case id, label, volume }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        volume = try container.decode(VolumeIdentity.self, forKey: .volume)
        rootPath = "" // Resolved from an app-scoped bookmark, never from portable JSON.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(volume, forKey: .volume)
    }
}

public struct TransferPlan: Codable, Sendable {
    public let id: UUID
    public var name: String
    public var mode: TransferMode
    public var sourceRootPath: String
    public var sourceVolume: VolumeIdentity
    public var files: [SourceFile]
    public var destinations: [DestinationPlan]

    public init(id: UUID = UUID(), name: String, mode: TransferMode,
                sourceRootPath: String, sourceVolume: VolumeIdentity,
                files: [SourceFile], destinations: [DestinationPlan]) {
        self.id = id
        self.name = name
        self.mode = mode
        self.sourceRootPath = sourceRootPath
        self.sourceVolume = sourceVolume
        self.files = files
        self.destinations = destinations
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

/// `skipped` means an existing destination file was cryptographically confirmed
/// to already satisfy the transfer. `conflicted` means CardVault stopped rather
/// than overwrite something it could not account for.
public enum CopyState: String, Codable, Sendable { case pending, copying, copied, skipped, conflicted, failed }
public enum VerificationResult: String, Codable, Sendable { case pending, verified, mismatch, failed }

public struct DestinationFileResult: Codable, Hashable, Sendable {
    public var copyState: CopyState
    public var verification: VerificationResult
    public var destinationChecksum: String?
    public var error: String?
    /// How an existing file at this destination path was classified, when one
    /// was found. Recorded durably so a skip or a pause stays auditable.
    public var conflict: ConflictClassification?
    /// What became of the source's dates on this copy. Absent in manifests
    /// written before timestamps were carried over, so `schemaVersion` stays 1.
    /// Kept separate from `verification` because a date is not content: this
    /// never changes whether the copy is verified.
    public var timestamps: TimestampOutcome?

    public init(copyState: CopyState = .pending, verification: VerificationResult = .pending,
                destinationChecksum: String? = nil, error: String? = nil,
                conflict: ConflictClassification? = nil,
                timestamps: TimestampOutcome? = nil) {
        self.copyState = copyState
        self.verification = verification
        self.destinationChecksum = destinationChecksum
        self.error = error
        self.conflict = conflict
        self.timestamps = timestamps
    }
}
