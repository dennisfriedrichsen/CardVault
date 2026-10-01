import Foundation

/// Whether the drive a destination was written to is here now. Availability is
/// about reachability only: a destination that is not connected is still a
/// destination that was verified, and is never reported as unverified.
public enum HistoryDestinationAvailability: String, Sendable {
    /// The transfer's tree is readable and the volume identifies as the one recorded.
    case available
    /// The tree is readable but the volume cannot identify itself well enough to confirm.
    case indeterminate
    /// Something is mounted where the transfer was written, but it is not the volume recorded.
    case mismatched
    /// Nothing readable is there. The drive is disconnected, or the transfer was moved.
    case missing

    public var isReadable: Bool { self == .available || self == .indeterminate }

    public var title: String {
        switch self {
        case .available: "Connected"
        case .indeterminate: "Connected — identity unconfirmed"
        case .mismatched: "Different volume"
        case .missing: "Not connected"
        }
    }
}

/// One destination of a past transfer: what it recorded then, and what can be
/// done with it now.
public struct HistoryDestinationStatus: Sendable, Identifiable {
    public let destinationID: UUID
    public var id: UUID { destinationID }
    public let label: String
    public let recordedVolume: VolumeIdentity
    public let result: HistoryDestinationResult?
    public let availability: HistoryDestinationAvailability
    /// The transfer's folder on that drive, when it is readable.
    public let transferRoot: URL?
    public let manifestURL: URL?

    public init(destinationID: UUID, label: String, recordedVolume: VolumeIdentity,
                result: HistoryDestinationResult?, availability: HistoryDestinationAvailability,
                transferRoot: URL?, manifestURL: URL?) {
        self.destinationID = destinationID
        self.label = label
        self.recordedVolume = recordedVolume
        self.result = result
        self.availability = availability
        self.transferRoot = transferRoot
        self.manifestURL = manifestURL
    }

    public var isVerified: Bool { result?.isFullyVerified == true }

    /// What was verified, stated without reference to whether the drive is here.
    public var verificationSummary: String {
        guard let result else { return "No result was recorded for this destination." }
        if result.isFullyVerified {
            return "All \(result.verifiedFiles) files verified independently at this destination."
        }
        var parts = ["\(result.verifiedFiles) of \(result.totalFiles) files verified"]
        if result.mismatchedFiles > 0 { parts.append("\(result.mismatchedFiles) mismatched") }
        if result.failedFiles > 0 { parts.append("\(result.failedFiles) failed verification") }
        if result.conflictedFiles > 0 { parts.append("\(result.conflictedFiles) paused on a conflict") }
        return parts.joined(separator: " · ")
    }

    public var canReveal: Bool { transferRoot != nil }
    public var canOpenManifest: Bool { manifestURL != nil }

    /// Why the Finder action is unavailable, or nil when it is available.
    public var revealUnavailableReason: String? {
        canReveal ? nil : unreachableReason
    }

    public var manifestUnavailableReason: String? {
        canOpenManifest ? nil : unreachableReason
    }

    private var unreachableReason: String {
        switch availability {
        case .missing:
            "\(recordedVolume.displayName) is not connected. Reconnect it to open this destination."
        case .mismatched:
            "The volume mounted where this transfer was written is not \(recordedVolume.displayName)."
        case .available, .indeterminate:
            "This destination's folder could not be found on \(recordedVolume.displayName)."
        }
    }
}

/// A field where the local index disagrees with the portable manifest. The
/// manifest is authoritative in every case; the index is only an index.
public struct HistoryDiscrepancy: Sendable, Identifiable, Hashable {
    public var id: String { field }
    public let field: String
    public let indexValue: String
    public let manifestValue: String

    public init(field: String, indexValue: String, manifestValue: String) {
        self.field = field
        self.indexValue = indexValue
        self.manifestValue = manifestValue
    }
}

/// Everything the history detail view shows for one past transfer, assembled
/// from the index and, where a drive is connected, from the manifest itself.
public struct HistoryDetail: Sendable, Identifiable {
    public var id: UUID { entry.id }
    public let entry: TransferHistoryEntry
    public let destinations: [HistoryDestinationStatus]
    /// The authoritative record, read back from a connected destination.
    public let manifest: TransferManifest?
    public let manifestURL: URL?
    /// Why the authoritative record could not be consulted, when it could not be.
    public let manifestUnavailableReason: String?
    public let discrepancies: [HistoryDiscrepancy]

    public init(entry: TransferHistoryEntry, destinations: [HistoryDestinationStatus],
                manifest: TransferManifest?, manifestURL: URL?,
                manifestUnavailableReason: String?, discrepancies: [HistoryDiscrepancy]) {
        self.entry = entry
        self.destinations = destinations
        self.manifest = manifest
        self.manifestURL = manifestURL
        self.manifestUnavailableReason = manifestUnavailableReason
        self.discrepancies = discrepancies
    }

    public var availableDestinations: [HistoryDestinationStatus] {
        destinations.filter { $0.availability.isReadable }
    }
    public var missingDestinations: [HistoryDestinationStatus] {
        destinations.filter { !$0.availability.isReadable }
    }

    /// True when the index and the manifest agree. False is not a fault in the
    /// transfer: it means the index is stale and the manifest should be read.
    public var indexAgreesWithManifest: Bool { manifest != nil && discrepancies.isEmpty }

    /// The one sentence the UI leads with when the index cannot be trusted.
    public var authorityNote: String? {
        if manifest == nil {
            return "The portable manifest is the authoritative record of this transfer. "
                + (manifestUnavailableReason ?? "It could not be read from any connected destination.")
                + " What follows is the local index, which is only a convenience copy."
        }
        guard !discrepancies.isEmpty else { return nil }
        return "The local index disagrees with the portable manifest. The manifest on the destination is authoritative."
    }
}

/// Reads past transfers back. Every method here opens files for reading only:
/// inspecting history never repairs, moves, finalizes, or rewrites anything.
public actor TransferHistoryInspector {
    private let manifestStore: ManifestStore
    private let resolver: VolumeIdentityResolver
    private let fileManager: FileManager

    public init(manifestStore: ManifestStore = ManifestStore(),
                resolver: VolumeIdentityResolver = VolumeIdentityResolver(provider: DiskArbitrationTopologyProvider()),
                fileManager: FileManager = .default) {
        self.manifestStore = manifestStore
        self.resolver = resolver
        self.fileManager = fileManager
    }

    /// Whether each destination of one past transfer is reachable right now.
    public func availability(for entry: TransferHistoryEntry) -> [HistoryDestinationStatus] {
        entry.destinations.map { destination in
            let result = entry.result(for: destination.id)
            guard let path = result?.manifestPath, !path.isEmpty else {
                return HistoryDestinationStatus(
                    destinationID: destination.id, label: destination.label,
                    recordedVolume: destination.volume, result: result,
                    availability: .missing, transferRoot: nil, manifestURL: nil)
            }
            let manifestURL = URL(filePath: path)
            // `<transfer root>/.cardvault/transfer-manifest.json`
            let transferRoot = manifestURL.deletingLastPathComponent().deletingLastPathComponent()
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                return HistoryDestinationStatus(
                    destinationID: destination.id, label: destination.label,
                    recordedVolume: destination.volume, result: result,
                    availability: .missing, transferRoot: nil, manifestURL: nil)
            }
            // A drive that moved is still the same drive; a different drive
            // mounted at the same path is not, however its label reads.
            let availability = match(recorded: destination.volume, at: transferRoot)
            let reachable = availability.isReadable
            return HistoryDestinationStatus(
                destinationID: destination.id, label: destination.label,
                recordedVolume: destination.volume, result: result,
                availability: availability,
                transferRoot: reachable ? transferRoot : nil,
                manifestURL: reachable ? manifestURL : nil)
        }
    }

    /// The full detail for one entry, with the manifest read back from the first
    /// connected destination that can supply it.
    public func detail(for entry: TransferHistoryEntry) async -> HistoryDetail {
        let destinations = availability(for: entry)
        var manifest: TransferManifest?
        var manifestURL: URL?
        var failureReason: String?

        for status in destinations {
            guard let url = status.manifestURL else { continue }
            do {
                manifest = try await manifestStore.load(from: url)
                manifestURL = url
                break
            } catch {
                failureReason = "\(status.label): \(describe(error))"
            }
        }

        let reason: String?
        if manifest != nil {
            reason = nil
        } else if let failureReason {
            reason = failureReason
        } else if destinations.isEmpty {
            reason = "No destination was recorded for this transfer."
        } else {
            reason = "None of this transfer's destinations are connected."
        }
        return HistoryDetail(entry: entry, destinations: destinations, manifest: manifest,
                             manifestURL: manifestURL, manifestUnavailableReason: reason,
                             discrepancies: manifest.map { compare(entry: entry, to: $0) } ?? [])
    }

    /// Rebuilds index entries from the manifests on connected drives. Used when
    /// the local index is missing or behind: the drives carry the truth, so a
    /// wiped index costs the user nothing but a rescan.
    public func rebuildEntries(fromDestinationRoots roots: [URL]) async -> [TransferHistoryEntry] {
        var byTransfer: [UUID: (manifest: TransferManifest, paths: [UUID: String])] = [:]
        for root in dedupe(roots) {
            for candidate in finishedTransferDirectories(in: root) {
                let manifestURL = TransferLayout.manifestURL(inStaging: candidate)
                guard fileManager.fileExists(atPath: manifestURL.path),
                      let manifest = try? await manifestStore.load(from: manifestURL),
                      manifest.completedAt != nil || manifest.state == .verified else { continue }
                var record = byTransfer[manifest.transferID] ?? (manifest, [:])
                record.manifest = manifest
                if let destination = destinationID(of: manifest, at: candidate) {
                    record.paths[destination] = manifestURL.path
                }
                byTransfer[manifest.transferID] = record
            }
        }
        return byTransfer.values.map { record in
            TransferHistoryEntry(manifest: record.manifest, manifestPaths: record.paths)
        }
    }

    /// Which destination wrote the tree found here, decided by volume identity
    /// rather than by folder name. A transfer with one destination needs no test.
    private func destinationID(of manifest: TransferManifest, at transferRoot: URL) -> UUID? {
        if manifest.destinations.count == 1 { return manifest.destinations[0].id }
        return manifest.destinations.first {
            match(recorded: $0.volume, at: transferRoot) == .available
        }?.id
    }

    private func finishedTransferDirectories(in root: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func compare(entry: TransferHistoryEntry, to manifest: TransferManifest) -> [HistoryDiscrepancy] {
        var found: [HistoryDiscrepancy] = []
        if entry.name != manifest.transferName {
            found.append(.init(field: "Transfer name", indexValue: entry.name, manifestValue: manifest.transferName))
        }
        if entry.finalState != manifest.state {
            found.append(.init(field: "Final state", indexValue: entry.finalState.rawValue,
                               manifestValue: manifest.state.rawValue))
        }
        if entry.totalFiles != manifest.files.count {
            found.append(.init(field: "Files", indexValue: "\(entry.totalFiles)",
                               manifestValue: "\(manifest.files.count)"))
        }
        let manifestBytes = manifest.files.reduce(0) { $0 + $1.byteCount }
        if entry.totalBytes != manifestBytes {
            found.append(.init(field: "Bytes", indexValue: "\(entry.totalBytes)", manifestValue: "\(manifestBytes)"))
        }
        for destination in manifest.destinations {
            let authoritative = HistoryDestinationResult(manifest: manifest, destinationID: destination.id,
                                                         manifestPath: nil)
            guard let indexed = entry.result(for: destination.id) else {
                found.append(.init(field: "\(destination.label) result", indexValue: "not recorded",
                                   manifestValue: "\(authoritative.verifiedFiles) of \(authoritative.totalFiles) verified"))
                continue
            }
            if indexed.verifiedFiles != authoritative.verifiedFiles {
                found.append(.init(field: "\(destination.label) verified files",
                                   indexValue: "\(indexed.verifiedFiles)",
                                   manifestValue: "\(authoritative.verifiedFiles)"))
            }
        }
        return found
    }

    private func match(recorded: VolumeIdentity, at url: URL) -> HistoryDestinationAvailability {
        let current = resolver.identity(for: url, defaultName: url.lastPathComponent)
        switch recorded.relation(to: current) {
        case .sameVolume: return .available
        // A different export on the server this transfer used is a different tree,
        // so what stands there now is not the copy history recorded.
        case .sameDevice, .sameServer, .distinct: return .mismatched
        case .indeterminate: return .indeterminate
        }
    }

    private func dedupe(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private nonisolated func describe(_ error: Error) -> String {
        switch error {
        case ManifestError.unsupportedSchema(let version):
            "The manifest uses schema version \(version), which this version of CardVault cannot read."
        default:
            (error as? LocalizedError)?.errorDescription ?? "The manifest could not be read."
        }
    }
}
