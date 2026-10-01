import Foundation

/// Where a `VolumeIdentity` came from. Disk Arbitration distinguishes partitions on a shared
/// physical device; the public URL resource keys cannot, so they are only a documented fallback.
public enum VolumeIdentitySource: String, Codable, Sendable {
    case diskArbitration
    case urlResourceValues
}

/// A volume's position in the physical storage topology: which partition it is, and which
/// whole physical device that partition lives on.
///
/// Only a volume with a BSD device has one, which is why nothing here describes a network
/// mount. `DADiskGetBSDName` returns nothing for an NFS or SMB share, so Disk Arbitration's
/// own `DAVolumeNetwork` flag can never be read back out of this type — it carried an
/// `isNetwork` field that no network volume ever reached. Locality and server identity come
/// from `MountFacts` instead, which answers for every mount.
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
    public let deviceModel: String?

    public init(partitionIdentifier: String, wholeDeviceIdentifier: String,
                volumeUUID: UUID? = nil, mediaUUID: UUID? = nil,
                volumeName: String? = nil, fileSystem: String? = nil, mountPath: String? = nil,
                isRemovable: Bool = false, isEjectable: Bool = false,
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

/// Where a network mount came from, as the mount itself reports it: the server it names and
/// the export or share on that server.
///
/// This is deliberately not a `physicalStoreIdentifier`. Two mounts naming one host are served
/// by one machine, which is enough to say they are not independent copies of each other; it
/// says nothing about how many disk sets stand behind them, and CardVault cannot see the
/// server's disks to find out. The rule that a fallback-resolved identity may not claim two
/// paths share a physical device therefore stands unchanged — this is a different fact, on its
/// own footing.
public struct NetworkVolumeOrigin: Codable, Hashable, Sendable {
    /// Lower-cased, without any user name or port. Compared literally: one server answers to
    /// many names, so a shared host proves the two mounts are not independent while a differing
    /// host proves nothing at all.
    public let host: String
    /// The exported path (`/mnt/tank/files-photos`) or share (`/photos-fast`).
    public let exportPath: String
    /// The mount's own type token, as `statfs` spells it: `nfs`, `smbfs`.
    public let fileSystemType: String

    public init(host: String, exportPath: String, fileSystemType: String) {
        self.host = host
        self.exportPath = exportPath
        self.fileSystemType = fileSystemType
    }

    /// The export's parent path, when there is one above the root: `/mnt/tank/files-photos`
    /// yields `/mnt/tank`, and a share named at the root yields nil.
    ///
    /// Only ever corroboration. `/mnt/<pool>/<dataset>` is a naming convention the server chose
    /// and the client cannot verify — two pools could share disks, and one prefix could cover
    /// unrelated storage — so a shared prefix raises confidence and never settles anything.
    /// Root is excluded because every share named at the root of every server shares it.
    public var exportPrefix: String? {
        var components = exportPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return nil }
        components.removeLast()
        return "/" + components.joined(separator: "/")
    }

    /// Parses `statfs`'s `f_mntfromname`. NFS spells it `host:/export`; SMB and AFP spell it
    /// with two leading slashes, an optional user name, and the share. A source string this
    /// does not recognise yields nil: an unparsed mount is treated as no information rather
    /// than guessed at.
    public init?(mountedFrom: String, fileSystemType: String) {
        let text = mountedFrom.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("/dev/") else { return nil }
        let authority: Substring
        let export: Substring
        if text.hasPrefix("//") {
            let body = text.dropFirst(2)
            guard let slash = body.firstIndex(of: "/") else { return nil }
            var head = body[..<slash]
            // Credentials belong to whoever mounted the share, not to the server it points at,
            // so two mounts of one host still compare equal across accounts.
            if let at = head.lastIndex(of: "@") { head = head[head.index(after: at)...] }
            authority = head
            export = body[slash...]
        } else if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            // A bracketed IPv6 literal: the colons inside it are not the host/export separator.
            authority = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            export = rest.dropFirst()
        } else if let colon = text.firstIndex(of: ":") {
            authority = text[..<colon]
            export = text[text.index(after: colon)...]
        } else {
            return nil
        }
        guard export.hasPrefix("/"), let host = Self.normalizedHost(authority) else { return nil }
        var path = String(export)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        self.init(host: host, exportPath: path, fileSystemType: fileSystemType.lowercased())
    }

    private static func normalizedHost(_ authority: Substring) -> String? {
        var text = authority
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = text[text.index(after: text.startIndex)..<close]
        } else if let colon = text.lastIndex(of: ":"), !text[..<colon].contains(":") {
            // Only a name can carry a bare `:port`. A second colon anywhere earlier means the
            // whole string is an unbracketed IPv6 address, whose last group is not a port.
            let port = text[text.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) { text = text[..<colon] }
        }
        // A trailing dot makes a name fully qualified without making it another server.
        var host = text.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

/// What `statfs(2)` reports about the mount a path is on.
///
/// It answers the question neither Disk Arbitration nor the URL resource keys will for a
/// network mount: which server and export it came from. The call is public and needs no
/// privilege. Like every other probe of a mount it blocks while that mount is unresponsive, so
/// it belongs where the URL resource reads already are and nowhere new.
public struct MountFacts: Hashable, Sendable {
    /// `f_fstypename`: the mount's own type token — `apfs`, `nfs`, `smbfs`.
    public let fileSystemType: String
    /// `f_mntfromname`: a device path for a local volume, and the server and export for a
    /// network one.
    public let mountedFrom: String
    /// `MNT_LOCAL`, which is the same bit `URLResourceKey.volumeIsLocalKey` reports.
    public let isLocal: Bool

    public init(fileSystemType: String, mountedFrom: String, isLocal: Bool) {
        self.fileSystemType = fileSystemType
        self.mountedFrom = mountedFrom
        self.isLocal = isLocal
    }

    public var networkOrigin: NetworkVolumeOrigin? {
        guard !isLocal else { return nil }
        return NetworkVolumeOrigin(mountedFrom: mountedFrom, fileSystemType: fileSystemType)
    }

    public static func read(from url: URL) -> MountFacts? {
        var buffer = statfs()
        guard statfs(url.standardizedFileURL.path, &buffer) == 0 else { return nil }
        return MountFacts(
            fileSystemType: text(of: buffer.f_fstypename, capacity: Int(MFSTYPENAMELEN)),
            mountedFrom: text(of: buffer.f_mntfromname, capacity: Int(MAXPATHLEN)),
            isLocal: buffer.f_flags & UInt32(MNT_LOCAL) != 0)
    }

    /// `statfs` returns its char arrays as fixed-size tuples, which have no String initialiser.
    private static func text<Tuple>(of tuple: Tuple, capacity: Int) -> String {
        withUnsafePointer(to: tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}

/// Builds a `VolumeIdentity` from Disk Arbitration when available, otherwise from public URL
/// resource values. Both paths are pure functions of injected facts, so unit tests need no media.
public struct VolumeIdentityResolver: Sendable {
    private let provider: VolumeTopologyProvider?
    private let factsProvider: @Sendable (URL) -> URLResourceVolumeFacts
    private let mountProvider: @Sendable (URL) -> MountFacts?

    public init(provider: VolumeTopologyProvider?) {
        self.init(provider: provider, factsProvider: URLResourceVolumeFacts.read(from:))
    }

    public init(provider: VolumeTopologyProvider?,
                factsProvider: @escaping @Sendable (URL) -> URLResourceVolumeFacts,
                mountProvider: @escaping @Sendable (URL) -> MountFacts? = MountFacts.read(from:)) {
        self.provider = provider
        self.factsProvider = factsProvider
        self.mountProvider = mountProvider
    }

    public func identity(for url: URL, defaultName: String, assumeRemovable: Bool = false) -> VolumeIdentity {
        let facts = factsProvider(url)
        // A network mount has no BSD device, so Disk Arbitration always throws for one and the
        // origin is only ever read here. It is asked of every path all the same: whether a
        // volume is a network mount is the mount's answer to give, not something inferred from
        // which identity source happened to succeed.
        let networkOrigin = mountProvider(url)?.networkOrigin
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
                identitySource: .urlResourceValues,
                networkOrigin: networkOrigin
            )
        }
        let volumeUUID = node.volumeUUID ?? facts.volumeUUID
        return VolumeIdentity(
            volumeUUID: volumeUUID,
            resourceIdentifier: volumeUUID?.uuidString ?? node.partitionIdentifier,
            displayName: node.volumeName ?? facts.volumeName ?? defaultName,
            fileSystem: node.fileSystem ?? facts.fileSystem ?? "Unknown",
            isRemovable: node.isRemovable || node.isEjectable || assumeRemovable,
            isLocal: facts.isLocal,
            physicalStoreIdentifier: node.wholeDeviceIdentifier,
            partitionIdentifier: node.partitionIdentifier,
            identitySource: .diskArbitration,
            networkOrigin: networkOrigin
        )
    }
}

/// How two `VolumeIdentity` values relate. Mount paths and volume labels are deliberately not
/// part of the comparison: the same card mounted at `/Volumes/CARD 1` is still the same volume,
/// and a reformatted card that reuses its old label is not.
public enum VolumeRelation: String, Sendable {
    case sameVolume
    case sameDevice
    /// Two mounts served by one machine. Weaker than `sameDevice`, which names shared hardware:
    /// this only says one server answers for both, and the disks behind them are unknowable
    /// from here.
    case sameServer
    case distinct
    case indeterminate
}

extension VolumeIdentity {
    public func relation(to other: VolumeIdentity) -> VolumeRelation {
        if let mine = volumeUUID, let theirs = other.volumeUUID {
            if mine == theirs { return .sameVolume }
            if sharesPhysicalDevice(with: other) { return .sameDevice }
            // A UUID pair that differs settles that these are two volumes. It does not settle
            // that they are independent, which is a fact about the server behind them.
            return sharesNetworkServer(with: other) ? .sameServer : .distinct
        }
        if let mine = partitionIdentifier, let theirs = other.partitionIdentifier, mine == theirs {
            return .sameVolume
        }
        if sharesPhysicalDevice(with: other) { return .sameDevice }
        if let network = networkRelation(to: other) { return network }
        return .indeterminate
    }

    private func sharesPhysicalDevice(with other: VolumeIdentity) -> Bool {
        guard identitySource == .diskArbitration, other.identitySource == .diskArbitration,
              let mine = physicalStoreIdentifier, let theirs = other.physicalStoreIdentifier else { return false }
        return mine == theirs
    }

    /// One export mounted twice is one directory tree wearing two names, so it is the same
    /// volume by any definition that matters here. One host serving two exports is not the same
    /// volume, but is not two independent copies either. A differing host settles nothing: this
    /// compares the strings the mounts were given, and one server answers to several.
    private func networkRelation(to other: VolumeIdentity) -> VolumeRelation? {
        guard let mine = networkOrigin, let theirs = other.networkOrigin,
              mine.host == theirs.host else { return nil }
        return mine.exportPath == theirs.exportPath ? .sameVolume : .sameServer
    }

    private func sharesNetworkServer(with other: VolumeIdentity) -> Bool {
        guard let mine = networkOrigin, let theirs = other.networkOrigin else { return false }
        return mine.host == theirs.host
    }
}

/// The storage format families CardVault has to reason about.
///
/// `VolumeIdentity.fileSystem` arrives in one of two vocabularies and neither can
/// be assumed: Disk Arbitration supplies the stable `kDADiskDescriptionVolumeKindKey`
/// tokens (`apfs`, `hfs`, `exfat`, `msdos`), while the documented fallback supplies
/// `volumeLocalizedFormatDescription` — user-locale text such as `ExFAT` or
/// `MS-DOS (FAT32)`. Testing that localized text directly is why checks written for
/// `"exFAT"` never fired on a FAT volume, whose description is `MS-DOS (FAT32)`, so
/// both vocabularies are recognised here and callers compare against a format instead
/// of a string.
///
/// `msdos` covers FAT16 and FAT32 alike: Disk Arbitration reports one kind for both
/// and only the localized description separates them. Nothing CardVault checks needs
/// them apart.
public enum VolumeFormat: String, Sendable {
    case apfs, hfs, exfat, fat, other
}

extension VolumeFormat {
    public init(fileSystemDescription description: String) {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Disk Arbitration's volume kinds are exact tokens and are matched as
        // such. Everything below is localized prose, whose wording varies, so it
        // is matched loosely.
        switch text {
        case "apfs": self = .apfs; return
        case "hfs", "hfs+", "hfsplus": self = .hfs; return
        case "exfat": self = .exfat; return
        case "msdos": self = .fat; return
        default: break
        }
        if text.contains("exfat") { self = .exfat; return }
        // Probed after exFAT, whose name ends in the same three letters. A bare
        // "fat" counts only as its own word, so it cannot match inside an
        // unrelated volume name.
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if ["fat32", "fat16", "ms-dos"].contains(where: text.contains) || words.contains("fat") {
            self = .fat
            return
        }
        if text.contains("apfs") { self = .apfs; return }
        if text.contains("mac os extended") || text.contains("hfs") { self = .hfs; return }
        self = .other
    }

    /// True for the formats Windows reads natively, and therefore the ones whose
    /// contents are likely to be carried to a Windows machine later.
    public var isWindowsNative: Bool { self == .exfat || self == .fat }

    /// The largest file the format can store, for the formats that cap it.
    ///
    /// FAT refuses a file of 4 GiB or more outright, whatever the free space:
    /// measured on a FAT32 image with 6 GB available, where 4294967295 bytes
    /// wrote and 4294967296 failed with `EFBIG`. exFAT has no such limit, which
    /// is exactly why cameras moved to it for 4K video, so this must stay
    /// FAT-only. FAT16 shares the cap trivially — its whole volume tops out at
    /// 4 GB — so the one value covers both members of the family.
    public var maximumFileSize: Int64? { self == .fat ? 4_294_967_295 : nil }
}

extension VolumeIdentity {
    public var format: VolumeFormat { VolumeFormat(fileSystemDescription: fileSystem) }
}
