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
    private static let callbackQueue = DispatchQueue(label: "com.cardvault.disk-arbitration.callbacks")
    private static let requestQueue = DispatchQueue(label: "com.cardvault.disk-arbitration.requests")

    public init() {}

    public func eject(volumeAt url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let path = url.standardizedFileURL
            Self.requestQueue.async {
                continuation.resume(with: Result { try Self.ejectBlocking(volumeAt: path) })
            }
        }
    }

    private static func ejectBlocking(volumeAt url: URL) throws {
        let name = url.lastPathComponent
        func failure(_ reason: VolumeEjectionError.Reason) -> VolumeEjectionError {
            VolumeEjectionError(volumeName: name, volumePath: url.path, reason: reason)
        }

        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw failure(.sessionUnavailable) }
        DASessionSetDispatchQueue(session, callbackQueue)
        defer { DASessionSetDispatchQueue(session, nil) }

        guard let volumeDisk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
            throw failure(.sessionUnavailable)
        }
        let wholeDisk = DADiskCopyWholeDisk(volumeDisk) ?? volumeDisk
        let description = DADiskCopyDescription(wholeDisk) as? [String: Any] ?? [:]
        let ejectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false
        let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        guard ejectable || removable else { throw failure(.notEjectable) }

        if let dissent = perform(request: { context in
            DADiskUnmount(wholeDisk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), unmountCallback, context)
        }) {
            throw failure(dissent.status == DAReturn(kDAReturnBusy) ? .busy(dissent.message) : .unmountFailed(dissent.message))
        }

        if let dissent = perform(request: { context in
            DADiskEject(wholeDisk, DADiskEjectOptions(kDADiskEjectOptionDefault), ejectCallback, context)
        }) {
            throw failure(.ejectFailed(dissent.message))
        }
    }

    /// Issues one Disk Arbitration request and blocks the request queue until its callback lands
    /// on the (separate) callback queue. Returns the dissenter, if any.
    private static func perform(request: (UnsafeMutableRawPointer) -> Void) -> Dissent? {
        let box = DissentBox()
        request(Unmanaged.passRetained(box).toOpaque())
        box.wait()
        return box.dissent
    }
}

private struct Dissent: Sendable {
    let status: DAReturn
    let message: String?
}

private final class DissentBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var dissent: Dissent?

    func complete(_ dissenter: DADissenter?) {
        if let dissenter {
            dissent = Dissent(status: DADissenterGetStatus(dissenter),
                              message: DADissenterGetStatusString(dissenter) as String?)
        }
        semaphore.signal()
    }

    func wait() { semaphore.wait() }
}

private let unmountCallback: DADiskUnmountCallback = { _, dissenter, context in
    guard let context else { return }
    Unmanaged<DissentBox>.fromOpaque(context).takeRetainedValue().complete(dissenter)
}

private let ejectCallback: DADiskEjectCallback = { _, dissenter, context in
    guard let context else { return }
    Unmanaged<DissentBox>.fromOpaque(context).takeRetainedValue().complete(dissenter)
}
