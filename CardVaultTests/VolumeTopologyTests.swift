import Foundation
import Testing
@testable import CardVaultCore

private struct MockTopologyProvider: VolumeTopologyProvider {
    var nodes: [String: VolumeTopologyNode] = [:]

    func topology(forVolumeAt url: URL) throws -> VolumeTopologyNode {
        guard let node = nodes[url.standardizedFileURL.path] else {
            throw VolumeTopologyError.notFound(path: url.path)
        }
        return node
    }
}

private func node(partition: String, wholeDevice: String, uuid: UUID? = nil,
                  name: String? = nil, mountPath: String? = nil) -> VolumeTopologyNode {
    VolumeTopologyNode(partitionIdentifier: partition, wholeDeviceIdentifier: wholeDevice,
                       volumeUUID: uuid, volumeName: name, fileSystem: "exFAT", mountPath: mountPath,
                       isRemovable: true, isEjectable: true)
}

private func resolver(_ nodes: [String: VolumeTopologyNode],
                      facts: URLResourceVolumeFacts = URLResourceVolumeFacts()) -> VolumeIdentityResolver {
    VolumeIdentityResolver(provider: MockTopologyProvider(nodes: nodes), factsProvider: { _ in facts })
}

@Suite("Volume topology and ejection")
struct VolumeTopologyTests {
    @Test("Disk Arbitration identity carries partition and whole-device identifiers")
    func diskArbitrationIdentity() {
        let uuid = UUID()
        let identity = resolver(["/Volumes/CARD": node(partition: "disk4s1", wholeDevice: "disk4",
                                                       uuid: uuid, name: "CARD")])
            .identity(for: URL(filePath: "/Volumes/CARD"), defaultName: "CARD")
        #expect(identity.identitySource == .diskArbitration)
        #expect(identity.partitionIdentifier == "disk4s1")
        #expect(identity.physicalStoreIdentifier == "disk4")
        #expect(identity.volumeUUID == uuid)
        #expect(identity.isRemovable)
    }

    @Test("Public URL volume metadata remains the documented fallback")
    func urlResourceFallback() {
        let uuid = UUID()
        let facts = URLResourceVolumeFacts(volumeUUID: uuid, volumeName: "BACKUP",
                                           fileSystem: "APFS", isLocal: true, isRemovable: false)
        let identity = resolver([:], facts: facts)
            .identity(for: URL(filePath: "/Volumes/BACKUP"), defaultName: "fallback")
        #expect(identity.identitySource == .urlResourceValues)
        #expect(identity.displayName == "BACKUP")
        #expect(identity.partitionIdentifier == nil)
        #expect(identity.physicalStoreIdentifier == uuid.uuidString)
    }

    @Test("Partitions of one device are distinguished but recognized as the same device")
    func partitionsOfOneDevice() {
        let store = resolver([
            "/Volumes/One": node(partition: "disk4s1", wholeDevice: "disk4", uuid: UUID(), name: "One"),
            "/Volumes/Two": node(partition: "disk4s2", wholeDevice: "disk4", uuid: UUID(), name: "Two")
        ])
        let one = store.identity(for: URL(filePath: "/Volumes/One"), defaultName: "One")
        let two = store.identity(for: URL(filePath: "/Volumes/Two"), defaultName: "Two")
        #expect(one.partitionIdentifier != two.partitionIdentifier)
        #expect(one.relation(to: two) == .sameDevice)
    }

    @Test("The same volume at a new mount path is still the same volume")
    func remountedVolume() {
        let uuid = UUID()
        let store = resolver([
            "/Volumes/CARD": node(partition: "disk4s1", wholeDevice: "disk4", uuid: uuid,
                                  name: "CARD", mountPath: "/Volumes/CARD"),
            "/Volumes/CARD 1": node(partition: "disk6s1", wholeDevice: "disk6", uuid: uuid,
                                    name: "CARD", mountPath: "/Volumes/CARD 1")
        ])
        let first = store.identity(for: URL(filePath: "/Volumes/CARD"), defaultName: "CARD")
        let second = store.identity(for: URL(filePath: "/Volumes/CARD 1"), defaultName: "CARD")
        #expect(first.relation(to: second) == .sameVolume)
    }

    @Test("A reformatted volume reusing its label is a different volume")
    func reformattedVolume() {
        let store = resolver([
            "/Volumes/CARD": node(partition: "disk4s1", wholeDevice: "disk4", uuid: UUID(), name: "CARD"),
            "/Volumes/CARD-new": node(partition: "disk7s1", wholeDevice: "disk7", uuid: UUID(), name: "CARD")
        ])
        let before = store.identity(for: URL(filePath: "/Volumes/CARD"), defaultName: "CARD")
        let after = store.identity(for: URL(filePath: "/Volumes/CARD-new"), defaultName: "CARD")
        #expect(before.displayName == after.displayName)
        #expect(before.relation(to: after) == .distinct)
    }

    @Test("Destinations resolving to one volume are not independent copies")
    func sameVolumeDestinations() {
        let uuid = UUID()
        let identity = resolver(["/Volumes/CARD": node(partition: "disk4s1", wholeDevice: "disk4",
                                                       uuid: uuid, name: "CARD")])
            .identity(for: URL(filePath: "/Volumes/CARD"), defaultName: "CARD")
        let plan = TransferPlan(name: "T", mode: .preserveCard, sourceRootPath: "/Volumes/SOURCE",
                                sourceVolume: identity, files: [],
                                destinations: [
                                    DestinationPlan(label: "Primary", rootPath: "/Volumes/CARD/a", volume: identity),
                                    DestinationPlan(label: "Backup", rootPath: "/Volumes/CARD/b", volume: identity)
                                ])
        let result = TransferPreflightService(safetyMarginBytes: 0).validate(plan)
        #expect(result.issues.contains { $0.code == "same-volume" && $0.severity == .warning })
    }

    @Test("Independent devices raise no independence warning")
    func independentDestinations() {
        let store = resolver([
            "/Volumes/A": node(partition: "disk4s1", wholeDevice: "disk4", uuid: UUID(), name: "A"),
            "/Volumes/B": node(partition: "disk9s1", wholeDevice: "disk9", uuid: UUID(), name: "B")
        ])
        let primary = store.identity(for: URL(filePath: "/Volumes/A"), defaultName: "A")
        let backup = store.identity(for: URL(filePath: "/Volumes/B"), defaultName: "B")
        #expect(primary.relation(to: backup) == .distinct)
        let plan = TransferPlan(name: "T", mode: .preserveCard, sourceRootPath: "/Volumes/SOURCE",
                                sourceVolume: primary, files: [],
                                destinations: [
                                    DestinationPlan(label: "Primary", rootPath: "/Volumes/A", volume: primary),
                                    DestinationPlan(label: "Backup", rootPath: "/Volumes/B", volume: backup)
                                ])
        let result = TransferPreflightService(safetyMarginBytes: 0).validate(plan)
        #expect(!result.issues.contains { $0.code == "same-device" || $0.code == "same-volume" })
    }

    @Test("A busy ejection failure names the volume and offers a recovery action")
    func busyEjectionFailure() async {
        struct BusyEjector: DiskEjectionService {
            func eject(volumeAt url: URL) async throws {
                throw VolumeEjectionError(volumeName: "CARD", volumePath: url.path,
                                          reason: .busy("Finder is using the volume"))
            }
        }
        do {
            try await BusyEjector().eject(volumeAt: URL(filePath: "/Volumes/CARD"))
            Issue.record("Expected the ejection to fail")
        } catch let error as VolumeEjectionError {
            #expect(error.volumeName == "CARD")
            #expect(error.errorDescription?.contains("CARD") == true)
            #expect(error.recoverySuggestion?.contains("/Volumes/CARD") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

/// The whole-disk BSD name is read through a pointer owned by the disk object it describes.
/// Releasing that object before the read yields freed memory, so these run against the boot
/// volume — every Mac has one on a real device — rather than waiting for opt-in removable media.
@Suite("Disk Arbitration whole-disk identity")
struct DiskArbitrationWholeDiskTests {
    private let bootVolume = URL(filePath: "/")

    @Test("Whole-disk identity is a device identifier, not a slice or freed memory")
    func resolvesWholeDevice() throws {
        let node = try DiskArbitrationTopologyProvider().topology(forVolumeAt: bootVolume)
        #expect(node.wholeDeviceIdentifier.wholeMatch(of: /disk[0-9]+/) != nil)
        #expect(node.partitionIdentifier.hasPrefix(node.wholeDeviceIdentifier))
        // `?? bsdName` makes a failed read look plausible: a slice identifier passes every
        // prefix check against itself. Only a strict prefix proves the whole disk was read.
        #expect(node.wholeDeviceIdentifier != node.partitionIdentifier)
    }

    @Test("Whole-disk identity does not vary between resolutions")
    func wholeDeviceIdentifierIsStable() throws {
        let provider = DiskArbitrationTopologyProvider()
        let identifiers = try (0..<8).map { _ in
            try provider.topology(forVolumeAt: bootVolume).wholeDeviceIdentifier
        }
        // Freed bytes differ run to run; a device identifier does not.
        #expect(Set(identifiers).count == 1)
    }
}

/// Opt-in coverage for real hardware. Set `CARDVAULT_DEVICE_VOLUME` to a mounted removable
/// volume path, e.g. `CARDVAULT_DEVICE_VOLUME=/Volumes/CARD swift test`.
@Suite("Disk Arbitration on real media", .enabled(if: ProcessInfo.processInfo.environment["CARDVAULT_DEVICE_VOLUME"] != nil))
struct DiskArbitrationManualTests {
    private var volumeURL: URL {
        URL(filePath: ProcessInfo.processInfo.environment["CARDVAULT_DEVICE_VOLUME"] ?? "/")
    }

    @Test("Disk Arbitration describes the mounted volume")
    func describesVolume() throws {
        let node = try DiskArbitrationTopologyProvider().topology(forVolumeAt: volumeURL)
        #expect(node.partitionIdentifier.hasPrefix("disk"))
        #expect(node.partitionIdentifier.hasPrefix(node.wholeDeviceIdentifier))
        #expect(node.wholeDeviceIdentifier.wholeMatch(of: /disk[0-9]+/) != nil)
        // A card is always a slice of its device, so falling back to the partition identifier
        // is a failure to resolve the whole disk, not an acceptable answer.
        #expect(node.wholeDeviceIdentifier != node.partitionIdentifier)
    }

    /// Also set `CARDVAULT_DEVICE_EJECT=1`. This unmounts and ejects the device for real.
    @Test("Ejection unmounts and ejects the device",
          .enabled(if: ProcessInfo.processInfo.environment["CARDVAULT_DEVICE_EJECT"] == "1"))
    func ejectsVolume() async throws {
        try await DiskArbitrationEjectionService().eject(volumeAt: volumeURL)
        #expect(!FileManager.default.fileExists(atPath: volumeURL.path))
    }
}
