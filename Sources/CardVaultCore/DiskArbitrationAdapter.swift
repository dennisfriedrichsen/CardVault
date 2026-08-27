import DiskArbitration
import Foundation

/// Disk Arbitration is used read-only for identity, and for unattended unmount + eject.
/// It needs no privileged access and no helper tool.
public struct DiskArbitrationTopologyProvider: VolumeTopologyProvider {
    public init() {}

    public func topology(forVolumeAt url: URL) throws -> VolumeTopologyNode {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw VolumeTopologyError.sessionUnavailable }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url.standardizedFileURL as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let bsdName = DADiskGetBSDName(disk).flatMap({ String(validatingCString: $0) }), !bsdName.isEmpty
        else { throw VolumeTopologyError.notFound(path: url.path) }

        // DADiskGetBSDName returns a pointer owned by the disk it is asked about, so the whole
        // disk has to outlive the read. Chaining off the DADiskCopyWholeDisk temporary lets ARC
        // release it first, and the name is then read from freed memory.
        let wholeDisk = DADiskCopyWholeDisk(disk)
        let wholeName = wholeDisk
            .flatMap { DADiskGetBSDName($0) }
            .flatMap { String(validatingCString: $0) }
        withExtendedLifetime(wholeDisk) {}

        return VolumeTopologyNode(
            partitionIdentifier: bsdName,
            wholeDeviceIdentifier: wholeName ?? bsdName,
            volumeUUID: description.uuid(forKey: kDADiskDescriptionVolumeUUIDKey),
            mediaUUID: description.uuid(forKey: kDADiskDescriptionMediaUUIDKey),
            volumeName: description[kDADiskDescriptionVolumeNameKey as String] as? String,
            fileSystem: description[kDADiskDescriptionVolumeKindKey as String] as? String,
            mountPath: (description[kDADiskDescriptionVolumePathKey as String] as? URL)?.path,
            isRemovable: description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false,
            isEjectable: description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false,
            isNetwork: description[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false,
            deviceModel: description[kDADiskDescriptionDeviceModelKey as String] as? String
        )
    }
}

private extension [String: Any] {
    func uuid(forKey key: CFString) -> UUID? {
        guard let value = self[key as String], CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        let cfUUID = unsafeBitCast(value as CFTypeRef, to: CFUUID.self)
        return UUID(uuidString: CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String)
    }
}

public struct VolumeEjectionError: LocalizedError, Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case notEjectable
        case busy(String?)
        case unmountFailed(String?)
        case ejectFailed(String?)
        case sessionUnavailable
    }

    public let volumeName: String
    public let volumePath: String
    public let reason: Reason

    public init(volumeName: String, volumePath: String, reason: Reason) {
        self.volumeName = volumeName
        self.volumePath = volumePath
        self.reason = reason
    }

    public var errorDescription: String? {
        switch reason {
        case .notEjectable: "\(volumeName) is not a removable device that CardVault can eject."
        case .busy(let detail): "\(volumeName) is still in use\(detail.map { " (\($0))" } ?? "")."
        case .unmountFailed(let detail): "\(volumeName) could not be unmounted\(detail.map { ": \($0)" } ?? "")."
        case .ejectFailed(let detail): "\(volumeName) was unmounted but not ejected\(detail.map { ": \($0)" } ?? "")."
        case .sessionUnavailable: "\(volumeName) could not be reached through Disk Arbitration."
        }
    }

    public var recoverySuggestion: String? {
        switch reason {
        case .notEjectable: "Remove the reader itself, or eject the device from Finder."
        case .busy: "Close any app using \(volumePath) — Finder windows, Photos, or a previewer — then eject again. Your copies are already verified."
        case .unmountFailed, .sessionUnavailable: "Eject \(volumeName) from Finder. Do not unplug it until the volume disappears."
        case .ejectFailed: "\(volumeName) is unmounted and safe to unplug once its activity light is off."
        }
    }
}

/// Unmounts every partition of the card's physical device and then ejects the device.
public struct DiskArbitrationEjectionService: DiskEjectionService {
    private static let callbackQueue = DispatchQueue(label: "com.cardvault.disk-arbitration.callbacks",
                                                     qos: .userInitiated)

    public init() {}

    public func eject(volumeAt url: URL) async throws {
        let url = url.standardizedFileURL
        let name = url.lastPathComponent
        func failure(_ reason: VolumeEjectionError.Reason) -> VolumeEjectionError {
            VolumeEjectionError(volumeName: name, volumePath: url.path, reason: reason)
        }

        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw failure(.sessionUnavailable) }
        DASessionSetDispatchQueue(session, Self.callbackQueue)
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let volumeDisk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            throw failure(.sessionUnavailable)
        }
        let wholeDisk = DADiskCopyWholeDisk(volumeDisk) ?? volumeDisk
        let description = DADiskCopyDescription(wholeDisk) as? [String: Any] ?? [:]
        let ejectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false
        let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        guard ejectable || removable else { throw failure(.notEjectable) }

        if let dissent = await Self.perform(request: { context in
            DADiskUnmount(wholeDisk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), unmountCallback, context)
        }) {
            throw failure(dissent.status == DAReturn(kDAReturnBusy) ? .busy(dissent.message) : .unmountFailed(dissent.message))
        }

        if let dissent = await Self.perform(request: { context in
            DADiskEject(wholeDisk, DADiskEjectOptions(kDADiskEjectOptionDefault), ejectCallback, context)
        }) {
            throw failure(.ejectFailed(dissent.message))
        }
    }

    /// Issues one Disk Arbitration request and suspends until its callback lands on the callback
    /// queue. Nothing blocks a thread: a semaphore here would park the caller's user-initiated
    /// thread on the callback queue and invert priorities.
    private static func perform(request: (UnsafeMutableRawPointer) -> Void) async -> Dissent? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Dissent?, Never>) in
            request(Unmanaged.passRetained(DissentBox(continuation)).toOpaque())
        }
    }
}

private struct Dissent: Sendable {
    let status: DAReturn
    let message: String?
}

private final class DissentBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Dissent?, Never>

    init(_ continuation: CheckedContinuation<Dissent?, Never>) {
        self.continuation = continuation
    }

    func complete(_ dissenter: DADissenter?) {
        continuation.resume(returning: dissenter.map {
            Dissent(status: DADissenterGetStatus($0), message: DADissenterGetStatusString($0) as String?)
        })
    }
}

private let unmountCallback: DADiskUnmountCallback = { _, dissenter, context in
    guard let context else { return }
    Unmanaged<DissentBox>.fromOpaque(context).takeRetainedValue().complete(dissenter)
}

private let ejectCallback: DADiskEjectCallback = { _, dissenter, context in
    guard let context else { return }
    Unmanaged<DissentBox>.fromOpaque(context).takeRetainedValue().complete(dissenter)
}
