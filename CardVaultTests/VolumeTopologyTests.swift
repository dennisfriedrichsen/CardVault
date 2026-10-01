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
                      facts: URLResourceVolumeFacts = URLResourceVolumeFacts(),
                      mounts: [String: MountFacts] = [:]) -> VolumeIdentityResolver {
    VolumeIdentityResolver(provider: MockTopologyProvider(nodes: nodes), factsProvider: { _ in facts },
                           mountProvider: { mounts[$0.standardizedFileURL.path] })
}

/// A share as the resolver builds one: no volume UUID and no BSD device, because
/// a network mount reports neither.
private func networkIdentity(host: String = "mercury.local", export: String,
                             name: String? = nil, type: String = "nfs") -> VolumeIdentity {
    VolumeIdentity(displayName: name ?? export, fileSystem: "Network File System (NFS)",
                   isLocal: false, identitySource: .urlResourceValues,
                   networkOrigin: NetworkVolumeOrigin(host: host, exportPath: export, fileSystemType: type))
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

    /// Two shares on one NAS used to compare `.indeterminate`, which preflight
    /// passes over in silence, so CardVault told the user two exports of one pool
    /// were two independent copies.
    @Test("Two exports of one server are not independent copies")
    func exportsOfOneServerAreNotIndependent() {
        let primary = networkIdentity(export: "/mnt/tank/files-photos")
        let backup = networkIdentity(export: "/mnt/tank/files-local")
        #expect(primary.relation(to: backup) == .sameServer)
        #expect(backup.relation(to: primary) == .sameServer)
    }

    /// One export mounted twice is one directory tree under two names. Nothing in
    /// the paths says so, and the overlap check cannot see it either, because the
    /// two mount points really are different folders on this Mac.
    @Test("One export mounted twice is the same volume")
    func oneExportMountedTwiceIsOneVolume() {
        let first = networkIdentity(export: "/mnt/tank/files-photos", name: "files-photos")
        let second = networkIdentity(export: "/mnt/tank/files-photos", name: "files-photos-1")
        #expect(first.relation(to: second) == .sameVolume)
    }

    /// A differing host settles nothing: this compares the strings the mounts were
    /// given, and one server answers to several. Claiming `.distinct` would be
    /// claiming independence CardVault cannot see.
    @Test("Two different host names are never claimed to be independent")
    func differingHostsStayIndeterminate() {
        let mine = networkIdentity(host: "mercury.local", export: "/mnt/tank/files")
        let theirs = networkIdentity(host: "192.168.1.20", export: "/exports/photos")
        #expect(mine.relation(to: theirs) == .indeterminate)
    }

    /// The fallback rule stands: a network identity may say two paths share a
    /// server, never that they share a disk.
    @Test("A network identity never claims a shared physical device")
    func networkIdentityClaimsNoDevice() {
        let one = networkIdentity(export: "/mnt/tank/files-photos")
        let other = networkIdentity(export: "/mnt/tank001/files-fast")
        #expect(one.physicalStoreIdentifier == nil)
        #expect(one.partitionIdentifier == nil)
        #expect(one.relation(to: other) != .sameDevice)
    }

    @Test("A local volume is unaffected by the network comparison")
    func localVolumesIgnoreNetworkOrigin() {
        let store = resolver([
            "/Volumes/A": node(partition: "disk4s1", wholeDevice: "disk4", uuid: UUID(), name: "A"),
            "/Volumes/B": node(partition: "disk9s1", wholeDevice: "disk9", uuid: UUID(), name: "B")
        ])
        let one = store.identity(for: URL(filePath: "/Volumes/A"), defaultName: "A")
        let two = store.identity(for: URL(filePath: "/Volumes/B"), defaultName: "B")
        #expect(one.networkOrigin == nil)
        #expect(one.relation(to: two) == .distinct)
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

/// `statfs`'s `f_mntfromname` is the only public, non-privileged fact that names the server a
/// share came from. Every string below was measured on a real mount.
@Suite("Network mount identity")
struct NetworkVolumeOriginTests {

    @Test("An NFS mount reports its host and export")
    func parsesNFS() throws {
        let origin = try #require(NetworkVolumeOrigin(mountedFrom: "mercury.local:/mnt/tank/files-local",
                                                      fileSystemType: "nfs"))
        #expect(origin.host == "mercury.local")
        #expect(origin.exportPath == "/mnt/tank/files-local")
        #expect(origin.fileSystemType == "nfs")
    }

    /// The user name belongs to whoever mounted the share, not to the server it points at, so
    /// one host mounted under two accounts still compares as one host.
    @Test("An SMB mount reports its host without the account that mounted it")
    func parsesSMB() throws {
        let origin = try #require(NetworkVolumeOrigin(mountedFrom: "//denny@mercury.local/photos-fast",
                                                      fileSystemType: "smbfs"))
        #expect(origin.host == "mercury.local")
        #expect(origin.exportPath == "/photos-fast")
        let other = try #require(NetworkVolumeOrigin(mountedFrom: "//guest@mercury.local/bulk",
                                                     fileSystemType: "smbfs"))
        #expect(origin.host == other.host)
    }

    @Test("A host is compared without case, port, or trailing dot")
    func normalizesHost() throws {
        let names = ["MERCURY.Local:/export", "mercury.local.:/export", "//MERCURY.local:445/export"]
        let hosts = try names.map { try #require(NetworkVolumeOrigin(mountedFrom: $0, fileSystemType: "nfs")).host }
        #expect(Set(hosts) == ["mercury.local"])
    }

    /// The colons inside an IPv6 literal are not the host/export separator.
    @Test("A bracketed IPv6 host is not split on its own colons")
    func parsesIPv6() throws {
        let origin = try #require(NetworkVolumeOrigin(mountedFrom: "[fe80::1]:/exports/photos",
                                                      fileSystemType: "nfs"))
        #expect(origin.host == "fe80::1")
        #expect(origin.exportPath == "/exports/photos")
    }

    @Test("A local device and an unrecognised source yield no origin")
    func rejectsNonNetworkSources() {
        #expect(NetworkVolumeOrigin(mountedFrom: "/dev/disk3s1s1", fileSystemType: "apfs") == nil)
        #expect(NetworkVolumeOrigin(mountedFrom: "map -fstab", fileSystemType: "autofs") == nil)
        #expect(NetworkVolumeOrigin(mountedFrom: "//mercury.local", fileSystemType: "smbfs") == nil)
        #expect(NetworkVolumeOrigin(mountedFrom: "", fileSystemType: "nfs") == nil)
        // A host with nothing after the colon exports nothing.
        #expect(NetworkVolumeOrigin(mountedFrom: "mercury.local:", fileSystemType: "nfs") == nil)
    }

    /// Corroboration only. The prefix is the server's own naming convention and the client
    /// cannot check it, so root — which every share named at the top level shares — is excluded
    /// rather than reported as a match.
    @Test("The export prefix stops at the root it cannot distinguish")
    func exportPrefixExcludesRoot() {
        #expect(NetworkVolumeOrigin(host: "h", exportPath: "/mnt/tank/files-photos",
                                    fileSystemType: "nfs").exportPrefix == "/mnt/tank")
        #expect(NetworkVolumeOrigin(host: "h", exportPath: "/photos-fast",
                                    fileSystemType: "smbfs").exportPrefix == nil)
        #expect(NetworkVolumeOrigin(host: "h", exportPath: "/", fileSystemType: "nfs").exportPrefix == nil)
    }

    @Test("A local mount has no network origin however its source string reads")
    func localMountHasNoOrigin() {
        let local = MountFacts(fileSystemType: "apfs", mountedFrom: "/dev/disk3s1s1", isLocal: true)
        #expect(local.networkOrigin == nil)
        // MNT_LOCAL decides, so a local mount whose source happens to look remote is still local.
        let odd = MountFacts(fileSystemType: "apfs", mountedFrom: "host:/export", isLocal: true)
        #expect(odd.networkOrigin == nil)
    }

    /// Disk Arbitration throws for a network mount, so the origin has to survive the fallback
    /// path or it never reaches an identity at all.
    @Test("The fallback identity carries the origin Disk Arbitration cannot supply")
    func fallbackIdentityCarriesOrigin() throws {
        let store = resolver([:],
                             facts: URLResourceVolumeFacts(volumeName: "files-photos",
                                                           fileSystem: "Network File System (NFS)",
                                                           isLocal: false),
                             mounts: ["/Volumes/files-photos": MountFacts(
                                fileSystemType: "nfs",
                                mountedFrom: "mercury.local:/mnt/tank/files-photos",
                                isLocal: false)])
        let identity = store.identity(for: URL(filePath: "/Volumes/files-photos"), defaultName: "share")
        #expect(identity.identitySource == .urlResourceValues)
        #expect(!identity.isLocal)
        #expect(identity.networkOrigin?.host == "mercury.local")
        #expect(identity.networkOrigin?.exportPath == "/mnt/tank/files-photos")
    }
}

@Suite("Network destination preflight")
struct NetworkPreflightTests {

    private func plan(_ volumes: [VolumeIdentity], roots: [String]) -> TransferPlan {
        TransferPlan(name: "T", mode: .preserveCard, sourceRootPath: "/Volumes/EOS_DIGITAL",
                     sourceVolume: VolumeIdentity(displayName: "EOS_DIGITAL", isRemovable: true),
                     files: [SourceFile(relativePath: "IMG.CR3", byteCount: 1_024, mediaKind: .raw)],
                     destinations: zip(["Primary", "Backup"], zip(roots, volumes)).map {
                         DestinationPlan(label: $0.0, rootPath: $0.1.0, volume: $0.1.1)
                     })
    }

    private func service(_ capacity: @escaping @Sendable (URL) -> Int64?) -> TransferPreflightService {
        TransferPreflightService(safetyMarginBytes: 0, capacityProvider: capacity,
                                 readabilityProvider: { _ in true },
                                 caseSensitivityProvider: { _ in true })
    }

    private func share(_ export: String, host: String = "mercury.local") -> VolumeIdentity {
        VolumeIdentity(displayName: export, fileSystem: "Network File System (NFS)", isLocal: false,
                       identitySource: .urlResourceValues,
                       networkOrigin: NetworkVolumeOrigin(host: host, exportPath: export,
                                                          fileSystemType: "nfs"))
    }

    /// Two pools on one NAS is a legitimate pair, so this warns and reports what it saw rather
    /// than asserting a conclusion about disks it cannot see.
    @Test("Two exports of one server warn without claiming they share disks")
    func sameServerWarns() throws {
        let result = service({ url in url.path.contains("fast") ? 843_017_334_784 : 5_190_304_702_464 })
            .validate(plan([share("/mnt/tank/files-photos"), share("/mnt/tank001/files-fast")],
                           roots: ["/Volumes/files-photos", "/Volumes/files-fast"]))
        let issue = try #require(result.issues.first { $0.code == "same-server" })
        #expect(issue.severity == .warning)
        #expect(result.canProceed)
        #expect(issue.message.contains("mercury.local"))
        #expect(issue.message.contains("cannot confirm these are two independent copies"))
        // Different pools and different free space: nothing here looks like one pool.
        #expect(!issue.message.contains("exported from the same path"))
        #expect(!issue.message.contains("same free space"))
    }

    /// A shared export prefix and identical free space is what one pool exported twice looks
    /// like. The severity does not change — the evidence is circumstantial — but the wording does.
    @Test("A shared prefix and matching free space escalate the wording, not the severity")
    func sameServerEscalatesWording() throws {
        let result = service({ _ in 5_190_304_702_464 })
            .validate(plan([share("/mnt/tank/files-photos"), share("/mnt/tank/files-local")],
                           roots: ["/Volumes/files-photos", "/Volumes/files-local"]))
        let issue = try #require(result.issues.first { $0.code == "same-server" })
        #expect(issue.severity == .warning)
        #expect(result.canProceed)
        #expect(issue.message.contains("exported from the same path (/mnt/tank)"))
        #expect(issue.message.contains("same free space"))
        #expect(issue.message.contains("One pool exported twice looks exactly like that"))
    }

    /// One export mounted at two paths is one tree: the two mount points really are different
    /// folders on this Mac, so nothing else in preflight notices.
    @Test("One export mounted twice is reported as one volume, not one server")
    func oneExportMountedTwiceWarnsAsSameVolume() {
        let result = service({ _ in 5_190_304_702_464 })
            .validate(plan([share("/mnt/tank/files-photos"), share("/mnt/tank/files-photos")],
                           roots: ["/Volumes/files-photos", "/Volumes/files-photos-1"]))
        #expect(result.issues.contains { $0.code == "same-volume" && $0.severity == .warning })
        #expect(!result.issues.contains { $0.code == "same-server" })
    }

    @Test("Shares on two different servers raise no independence warning")
    func differentServersAreQuiet() {
        let result = service({ _ in 5_190_304_702_464 })
            .validate(plan([share("/mnt/tank/photos"), share("/exports/photos", host: "titan.local")],
                           roots: ["/Volumes/photos", "/Volumes/titan-photos"]))
        #expect(!result.issues.contains {
            ["same-server", "same-volume", "same-device"].contains($0.code)
        })
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

/// Opt-in coverage for a real mounted share, the counterpart to the removable-media suite below.
///
/// Set `CARDVAULT_NETWORK_VOLUME` to a mounted NFS or SMB share, e.g.
/// `CARDVAULT_NETWORK_VOLUME=/Volumes/files-photos swift test --disable-sandbox`. Set
/// `CARDVAULT_NETWORK_VOLUME_2` as well — another share on the same server — to cover the
/// independence relation the pure-function tests can only pose.
///
/// Everything here writes only inside a directory it creates and removes.
@Suite("Network shares on real mounts",
       .enabled(if: ProcessInfo.processInfo.environment["CARDVAULT_NETWORK_VOLUME"] != nil),
       .serialized)
struct NetworkVolumeManualTests {
    private var shareURL: URL {
        URL(filePath: ProcessInfo.processInfo.environment["CARDVAULT_NETWORK_VOLUME"] ?? "/",
            directoryHint: .isDirectory)
    }

    private var secondShareURL: URL? {
        ProcessInfo.processInfo.environment["CARDVAULT_NETWORK_VOLUME_2"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    private func identity(_ url: URL) -> VolumeIdentity {
        VolumeIdentityResolver(provider: DiskArbitrationTopologyProvider())
            .identity(for: url, defaultName: url.lastPathComponent)
    }

    @Test("The share reports the server and export it was mounted from")
    func shareReportsItsOrigin() throws {
        let facts = try #require(MountFacts.read(from: shareURL))
        #expect(!facts.isLocal)
        let origin = try #require(facts.networkOrigin, "\(facts.mountedFrom) was not recognised")
        #expect(!origin.host.isEmpty)
        #expect(origin.exportPath.hasPrefix("/"))
        #expect(["nfs", "smbfs", "afpfs", "webdav"].contains(origin.fileSystemType))
    }

    /// The gap this work closed, asserted on the real thing: a share supplies none of the
    /// identity facts the local path relies on, so without the origin two of them compare as
    /// nothing at all.
    @Test("A share supplies no volume UUID and no device, only its origin")
    func shareHasNoDeviceIdentity() {
        let identity = identity(shareURL)
        #expect(!identity.isLocal)
        #expect(identity.volumeUUID == nil)
        #expect(identity.partitionIdentifier == nil)
        #expect(identity.identitySource == .urlResourceValues)
        #expect(identity.networkOrigin != nil)
    }

    @Test("Two shares on one server are not reported as independent copies")
    func twoSharesOnOneServer() throws {
        let second = try #require(secondShareURL, "CARDVAULT_NETWORK_VOLUME_2 is not set")
        let one = identity(shareURL)
        let other = identity(second)
        try #require(one.networkOrigin?.host == other.networkOrigin?.host,
                     "the two shares are on different servers, so this cannot be measured here")
        // The same export mounted twice is one tree; two exports are one server.
        #expect([.sameVolume, .sameServer].contains(one.relation(to: other)))

        let plan = TransferPlan(name: "T", mode: .preserveCard, sourceRootPath: "/Volumes/EOS_DIGITAL",
                                sourceVolume: VolumeIdentity(displayName: "EOS_DIGITAL", isRemovable: true),
                                files: [],
                                destinations: [DestinationPlan(label: "Primary", rootPath: shareURL.path, volume: one),
                                               DestinationPlan(label: "Backup", rootPath: second.path, volume: other)])
        let issues = TransferPreflightService(safetyMarginBytes: 0).validate(plan).issues
        #expect(issues.contains { ["same-server", "same-volume"].contains($0.code) })
    }

    /// #41's read-back measurement showed the first read after a close runs at wire rate, which
    /// is NFS close-to-open consistency doing its job: every `open` revalidates against the
    /// server. `LocalFileSystem` opens the file afresh for each checksum, so a re-verification
    /// gets the same treatment as the first one and no cache bypass is needed — which is just as
    /// well, since `fcntl(F_NOCACHE)` measurably is not one on NFS.
    ///
    /// What is asserted here is the invariant that reasoning rests on: a digest is a function of
    /// what is on the share now, never of anything this process remembers about it.
    @Test("A checksum over a share re-reads the file rather than trusting an earlier read")
    func checksumRereadsTheShare() async throws {
        let directory = shareURL.appending(path: "cardvault-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "IMG.CR3")
        let fileSystem = LocalFileSystem()
        try Data(repeating: 0xA1, count: 4_194_304).write(to: file)
        let first = try await fileSystem.checksum(file)
        #expect(try await fileSystem.checksum(file) == first)

        // Same length, different bytes: only a read that reaches the file can tell.
        try Data(repeating: 0xB2, count: 4_194_304).write(to: file)
        #expect(try await fileSystem.checksum(file) != first)
    }

    /// Issue #42's first acceptance criterion, run for real: one share, no local copy anywhere,
    /// through the coordinator that ships.
    @Test("A transfer to a share with no local copy runs to completion and verifies")
    func networkOnlyTransferVerifies() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "CardVaultNetwork-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source.appending(path: "DCIM/100EOS_R"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = shareURL.appending(path: "cardvault-test-\(UUID().uuidString)",
                                             directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        var files: [SourceFile] = []
        for index in 0..<3 {
            let relativePath = "DCIM/100EOS_R/IMG_000\(index).CR3"
            let bytes = Data(repeating: UInt8(index + 1), count: 2_097_152 + index)
            try bytes.write(to: source.appending(path: relativePath))
            files.append(SourceFile(relativePath: relativePath, byteCount: Int64(bytes.count), mediaKind: .raw))
        }

        let volume = identity(destination)
        let plan = TransferPlan(name: "NetworkOnly", mode: .preserveCard, sourceRootPath: source.path,
                                sourceVolume: VolumeIdentity(displayName: "CARD", isRemovable: true),
                                files: files,
                                destinations: [DestinationPlan(label: "Primary", rootPath: destination.path,
                                                               volume: volume)])

        // Preflight has to let it start at all: that is the rule this replaced.
        let preflight = TransferPreflightService(safetyMarginBytes: 0).validate(plan)
        #expect(preflight.canProceed)
        #expect(preflight.issues.contains { $0.code == "network-only" && $0.severity == .warning })

        let outcome = try await TransferCoordinator().execute(plan: plan) { _ in }
        #expect(outcome.state == .verified)
        #expect(outcome.safeToEject)
        let result = try #require(outcome.destinations.first)
        #expect(result.verifiedFiles == files.count)
        #expect(result.failedFiles == 0)
        let finalURL = try #require(result.finalURL)
        for file in files {
            let copied = TransferLayout.originalsRoot(inStaging: finalURL).appending(path: file.relativePath)
            #expect(FileManager.default.fileExists(atPath: copied.path), "\(file.relativePath) is missing")
        }
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
