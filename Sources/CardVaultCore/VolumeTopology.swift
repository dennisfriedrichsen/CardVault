import Foundation

/// Where a `VolumeIdentity` came from. Disk Arbitration distinguishes partitions on a shared
/// physical device; the public URL resource keys cannot, so they are only a documented fallback.
public enum VolumeIdentitySource: String, Codable, Sendable {
    case diskArbitration
    case urlResourceValues
}

/// A volume's position in the physical storage topology: which partition it is, and which
/// whole physical device that partition lives on.
public struct VolumeTopologyNode: Codable, Hashable, Sendable {
    /// BSD name of the partition backing the volume, e.g. `disk4s1`.
    public let partitionIdentifier: String
    /// BSD name of the whole physical device, e.g. `disk4`.
    public let wholeDeviceIdentifier: String
    public let volumeUUID: UUID?
    public let mediaUUID: UUID?
    public let volumeName: String?
    public let fileSystem: String?
    public let mountPath: String?
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isNetwork: Bool
    public let deviceModel: String?

    public init(partitionIdentifier: String, wholeDeviceIdentifier: String,
                volumeUUID: UUID? = nil, mediaUUID: UUID? = nil,
                volumeName: String? = nil, fileSystem: String? = nil, mountPath: String? = nil,
                isRemovable: Bool = false, isEjectable: Bool = false, isNetwork: Bool = false,
                deviceModel: String? = nil) {
        self.partitionIdentifier = partitionIdentifier
        self.wholeDeviceIdentifier = wholeDeviceIdentifier
        self.volumeUUID = volumeUUID
        self.mediaUUID = mediaUUID
        self.volumeName = volumeName
        self.fileSystem = fileSystem
        self.mountPath = mountPath
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isNetwork = isNetwork
        self.deviceModel = deviceModel
    }
}

public enum VolumeTopologyError: Error, Hashable, Sendable {
    case sessionUnavailable
    case notFound(path: String)
}

/// Service boundary over Disk Arbitration so the core stays testable without mounted media.
public protocol VolumeTopologyProvider: Sendable {
    func topology(forVolumeAt url: URL) throws -> VolumeTopologyNode
}

/// The public `URLResourceKey` values CardVault falls back to when Disk Arbitration cannot
/// describe a path (network mounts, synthetic roots, sandbox denials).
public struct URLResourceVolumeFacts: Sendable {
    public var volumeUUID: UUID?
    public var volumeName: String?
    public var fileSystem: String?
    public var isLocal: Bool
    public var isRemovable: Bool

    public init(volumeUUID: UUID? = nil, volumeName: String? = nil, fileSystem: String? = nil,
                isLocal: Bool = true, isRemovable: Bool = false) {
        self.volumeUUID = volumeUUID
        self.volumeName = volumeName
        self.fileSystem = fileSystem
        self.isLocal = isLocal
        self.isRemovable = isRemovable
    }

    public static func read(from url: URL) -> URLResourceVolumeFacts {
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey,
                                                       .volumeLocalizedFormatDescriptionKey,
                                                       .volumeIsLocalKey, .volumeIsRemovableKey])
        return URLResourceVolumeFacts(volumeUUID: values?.volumeUUIDString.flatMap(UUID.init(uuidString:)),
                                      volumeName: values?.volumeName,
                                      fileSystem: values?.volumeLocalizedFormatDescription,
                                      isLocal: values?.volumeIsLocal ?? true,
                                      isRemovable: values?.volumeIsRemovable ?? false)
    }
}

/// Builds a `VolumeIdentity` from Disk Arbitration when available, otherwise from public URL
/// resource values. Both paths are pure functions of injected facts, so unit tests need no media.
public struct VolumeIdentityResolver: Sendable {
    private let provider: VolumeTopologyProvider?
    private let factsProvider: @Sendable (URL) -> URLResourceVolumeFacts

    public init(provider: VolumeTopologyProvider?) {
        self.init(provider: provider, factsProvider: URLResourceVolumeFacts.read(from:))
    }

    public init(provider: VolumeTopologyProvider?,
                factsProvider: @escaping @Sendable (URL) -> URLResourceVolumeFacts) {
        self.provider = provider
        self.factsProvider = factsProvider
    }

    public func identity(for url: URL, defaultName: String, assumeRemovable: Bool = false) -> VolumeIdentity {
        let facts = factsProvider(url)
        guard let node = try? provider?.topology(forVolumeAt: url) else {
            return VolumeIdentity(
                volumeUUID: facts.volumeUUID,
                resourceIdentifier: facts.volumeUUID?.uuidString,
                displayName: facts.volumeName ?? defaultName,
                fileSystem: facts.fileSystem ?? "Unknown",
                isRemovable: assumeRemovable || facts.isRemovable,
                isLocal: facts.isLocal,
                physicalStoreIdentifier: facts.volumeUUID?.uuidString,
                partitionIdentifier: nil,
                identitySource: .urlResourceValues
            )
        }
        let volumeUUID = node.volumeUUID ?? facts.volumeUUID
        return VolumeIdentity(
            volumeUUID: volumeUUID,
            resourceIdentifier: volumeUUID?.uuidString ?? node.partitionIdentifier,
            displayName: node.volumeName ?? facts.volumeName ?? defaultName,
            fileSystem: node.fileSystem ?? facts.fileSystem ?? "Unknown",
            isRemovable: node.isRemovable || node.isEjectable || assumeRemovable,
            isLocal: !node.isNetwork,
            physicalStoreIdentifier: node.wholeDeviceIdentifier,
            partitionIdentifier: node.partitionIdentifier,
            identitySource: .diskArbitration
        )
    }
}

/// How two `VolumeIdentity` values relate. Mount paths and volume labels are deliberately not
/// part of the comparison: the same card mounted at `/Volumes/CARD 1` is still the same volume,
/// and a reformatted card that reuses its old label is not.
public enum VolumeRelation: String, Sendable {
    case sameVolume
    case sameDevice
    case distinct
    case indeterminate
}

extension VolumeIdentity {
    public func relation(to other: VolumeIdentity) -> VolumeRelation {
        if let mine = volumeUUID, let theirs = other.volumeUUID {
            if mine == theirs { return .sameVolume }
            return sharesPhysicalDevice(with: other) ? .sameDevice : .distinct
        }
        if let mine = partitionIdentifier, let theirs = other.partitionIdentifier, mine == theirs {
            return .sameVolume
        }
        if sharesPhysicalDevice(with: other) { return .sameDevice }
        return .indeterminate
    }

    private func sharesPhysicalDevice(with other: VolumeIdentity) -> Bool {
        guard identitySource == .diskArbitration, other.identitySource == .diskArbitration,
              let mine = physicalStoreIdentifier, let theirs = other.physicalStoreIdentifier else { return false }
        return mine == theirs
    }
}
