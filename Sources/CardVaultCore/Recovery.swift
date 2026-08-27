import Foundation

/// What a transfer was doing when it stopped. Derived from the last durable
/// manifest state, so it describes what actually happened rather than what the
/// UI happened to be showing when the process died.
public enum InterruptedOperation: String, Sendable {
    case scanningSource
    case copyingFiles
    case recordingCopyCompletion
    case verifyingFiles
    case awaitingConflictResolution
    case finalizing
    case stoppedByUser
    case unknown

    public var title: String {
        switch self {
        case .scanningSource: "Scanning the source"
        case .copyingFiles: "Copying files"
        case .recordingCopyCompletion: "Recording the completed copy"
        case .verifyingFiles: "Verifying copied files"
        case .awaitingConflictResolution: "Waiting on a destination conflict"
        case .finalizing: "Finalizing the transfer"
        case .stoppedByUser: "Stopped by you"
        case .unknown: "Unknown"
        }
    }

    public init(state: TransferState) {
        switch state {
        case .discoveringSource, .scanning: self = .scanningSource
        case .copying: self = .copyingFiles
        case .copyComplete: self = .recordingCopyCompletion
        case .verifying: self = .verifyingFiles
        case .needsAttention: self = .awaitingConflictResolution
        // `.safeToEject` on a staging tree is a record an older build wrote
        // over the outcome; the tree it describes never finished being moved.
        case .verified, .partiallySuccessful, .failed, .safeToEject: self = .finalizing
        // Nothing went wrong here, and recovery saying "Unknown" about a
        // transfer the user deliberately stopped reads as a fault report.
        case .cancelled: self = .stoppedByUser
        default: self = .unknown
        }
    }
}

/// Whether a destination CardVault recorded is the one currently mounted here.
/// Names and mount paths are never the test: a card reinserted at
/// `/Volumes/CARD 1` is the same card, and a reformatted card reusing its label
/// is not.
public enum RecoveryVolumeMatch: String, Sendable {
    case matched
    case mismatched
    case indeterminate
    case unavailable

    public var allowsResume: Bool { self == .matched || self == .indeterminate }
}

public struct RecoveredDestination: Sendable, Identifiable {
    /// The destination's plan UUID, stable across relaunches.
    public let id: UUID
    public let label: String
    public let recordedVolume: VolumeIdentity
    /// Where the destination is mounted now, if it is mounted at all.
    public let root: URL?
    public let stagingRoot: URL?
    public let manifestURL: URL?
    public let match: RecoveryVolumeMatch
    /// True when the bookmark had to be renewed, which usually means the drive
    /// was remounted somewhere else.
    public let bookmarkWasStale: Bool
    public let copiedFiles: Int
    public let verifiedFiles: Int
    public let conflictedFiles: Int

    public var isAvailable: Bool { root != nil }
}

public struct RecoveredSource: Sendable {
    public let recordedVolume: VolumeIdentity
    public let root: URL?
    public let match: RecoveryVolumeMatch
    public let bookmarkWasStale: Bool
    public var isAvailable: Bool { root != nil }
}

/// An unfinished transfer, described entirely from its durable manifest.
public struct RecoverableTransfer: Sendable, Identifiable {
    public var id: UUID { manifest.transferID }
    public let manifest: TransferManifest
    public let source: RecoveredSource
    public let destinations: [RecoveredDestination]

    public var name: String { manifest.transferName }
    public var lastDurableState: TransferState { manifest.state }
    public var interruptedOperation: InterruptedOperation { InterruptedOperation(state: manifest.state) }
    public var warnings: [String] { manifest.warnings }
    public var errors: [String] { manifest.errors }
    public var totalFiles: Int { manifest.files.count }
    public var totalBytes: Int64 { manifest.files.reduce(0) { $0 + $1.byteCount } }

    /// Files whose bytes reached every destination, whether or not they have
    /// been verified yet.
    public var completedFiles: Int {
        manifest.files.count { file in
            manifest.destinations.allSatisfy { destination in
                let state = file.destinations[destination.id]?.copyState
                return state == .copied || state == .skipped
            }
        }
    }

    /// Files verified at every destination. This is the only number that means
    /// the photographs are safe.
    public var verifiedFiles: Int {
        manifest.files.count { file in
            manifest.destinations.allSatisfy { file.destinations[$0.id]?.verification == .verified }
        }
    }

    public var remainingFiles: Int { totalFiles - verifiedFiles }

    /// Resume needs the source and every destination back. A drive mounted
    /// elsewhere is fine; a different drive wearing the same name is not.
    public var canResume: Bool {
        source.isAvailable && source.match.allowsResume
            && destinations.count == manifest.destinations.count
            && destinations.allSatisfy { $0.isAvailable && $0.match.allowsResume }
    }

    public var blockingReason: String? {
        if !source.isAvailable { return "Reconnect \(source.recordedVolume.displayName) to continue." }
        if source.match == .mismatched {
            return "The volume mounted where \(source.recordedVolume.displayName) was is a different volume."
        }
        if let missing = destinations.first(where: { !$0.isAvailable }) {
            return "Reconnect \(missing.recordedVolume.displayName) to continue."
        }
        if let wrong = destinations.first(where: { $0.match == .mismatched }) {
            return "\(wrong.label) is a different volume than the one this transfer wrote to."
        }
        if destinations.count != manifest.destinations.count {
            return "One of this transfer's destinations could not be located."
        }
        return nil
    }
}

/// A manifest that exists but cannot be trusted. Reported rather than skipped:
/// a transfer the user started must never disappear quietly, and must never be
/// restarted from a record this build does not understand.
public struct UnreadableTransfer: Sendable, Identifiable {
    public var id: String { manifestURL.path }
    public let manifestURL: URL
    public let stagingRoot: URL
    public let transferID: UUID?
    public let reason: String
    /// True when the manifest is newer than this build, which is a reason to
    /// update CardVault rather than to touch the files.
    public let isUnsupportedSchema: Bool
}

public struct RecoveryScan: Sendable {
    public let transfers: [RecoverableTransfer]
    public let unreadable: [UnreadableTransfer]
    public var isEmpty: Bool { transfers.isEmpty && unreadable.isEmpty }
}

// MARK: - Inspection

/// A read-only view of one file's fate across destinations.
public struct InspectedFile: Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let byteCount: Int64
    public let mediaKind: MediaKind
    public let sourceChecksum: String?
    public let destinations: [InspectedDestinationResult]
}

public struct InspectedDestinationResult: Sendable, Identifiable {
    public var id: UUID { destinationID }
    public let destinationID: UUID
    public let label: String
    public let copyState: CopyState
    public let verification: VerificationResult
    public let conflict: ConflictClassification?
    public let error: String?
}

public struct RecoveryInspection: Sendable, Identifiable {
    public var id: UUID { transferID }
    public let transferID: UUID
    public let transferName: String
    public let manifestURLs: [URL]
    public let files: [InspectedFile]
}

// MARK: - Abandoning

/// What abandoning would touch, computed before anything is removed so the user
/// is never asked to approve a deletion they cannot see.
public struct AbandonPlan: Sendable {
    /// Partial artifacts CardVault itself recorded as unfinished, each of them
    /// inside the transfer's own staging tree. These are the only files it is
    /// ever entitled to delete.
    public let removableIncompleteArtifacts: [URL]
    /// The same list as the user reads it: "Backup — DCIM/IMG_0435.CR3". The
    /// dialog shows these, because a count cannot be checked and a path can.
    public let removableDescriptions: [String]
    public let verifiedFilesKept: Int
    public let conflictedFilesKept: Int
    public let manifestsKept: [URL]
    /// Records naming a path outside the transfer's tree. Never removed, and
    /// surfaced so a tampered or damaged manifest is visible rather than silent.
    public let refusedPaths: [String]
    public var removesNothing: Bool { removableIncompleteArtifacts.isEmpty }

    public init(removableIncompleteArtifacts: [URL], removableDescriptions: [String],
                verifiedFilesKept: Int, conflictedFilesKept: Int, manifestsKept: [URL],
                refusedPaths: [String] = []) {
        self.removableIncompleteArtifacts = removableIncompleteArtifacts
        self.removableDescriptions = removableDescriptions
        self.verifiedFilesKept = verifiedFilesKept
        self.conflictedFilesKept = conflictedFilesKept
        self.manifestsKept = manifestsKept
        self.refusedPaths = refusedPaths
    }
}

public struct AbandonOutcome: Sendable {
    public let removedArtifacts: [URL]
    public let failures: [String]
    public let manifestsMarked: [URL]
}

public enum RecoveryError: Error, Equatable, Sendable {
    case sourceUnavailable
    case destinationUnavailable(label: String)
    case volumeMismatch(label: String)
    case manifestUnreadable(String)
}

// MARK: - Coordinator

public actor RecoveryCoordinator {
    private let manifestStore: ManifestStore
    private let resolver: VolumeIdentityResolver
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(manifestStore: ManifestStore = ManifestStore(),
                resolver: VolumeIdentityResolver = VolumeIdentityResolver(provider: DiskArbitrationTopologyProvider()),
                fileManager: FileManager = .default,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.manifestStore = manifestStore
        self.resolver = resolver
        self.fileManager = fileManager
        self.now = now
    }

    /// Finds every unfinished transfer reachable from the roots the caller could
    /// resolve. Reads only: discovery never repairs, moves, or restarts anything.
    ///
    /// `sourceRoots` and `destinationRoots` are keyed by transfer UUID because a
    /// transfer's roots come from its own bookmarks, not from whatever the user
    /// last selected.
    public func scan(destinationRoots: [URL],
                     sourceRoots: [UUID: SecurityScopedAccess] = [:],
                     transferDestinationRoots: [UUID: [UUID: SecurityScopedAccess]] = [:]) async -> RecoveryScan {
        var found: [UUID: [(root: URL, staging: URL, manifest: TransferManifest)]] = [:]
        var unreadable: [UnreadableTransfer] = []

        for root in dedupe(destinationRoots) {
            for staging in stagingDirectories(in: root) {
                let manifestURL = TransferLayout.manifestURL(inStaging: staging)
                guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
                do {
                    let manifest = try await manifestStore.load(from: manifestURL)
                    // An abandoned transfer is a record, not an offer. Nothing
                    // else is tested here: this is a staging directory, and a
                    // staging directory that still exists is by definition an
                    // unfinished transfer, whatever state its manifest names.
                    guard manifest.abandonedAt == nil else { continue }
                    found[manifest.transferID, default: []].append((root, staging, manifest))
                } catch {
                    unreadable.append(UnreadableTransfer(
                        manifestURL: manifestURL, stagingRoot: staging,
                        transferID: TransferLayout.transferID(fromStagingName: staging.lastPathComponent),
                        reason: describe(error),
                        isUnsupportedSchema: isUnsupportedSchema(error)))
                }
            }
        }

        var transfers: [RecoverableTransfer] = []
        for (transferID, entries) in found {
            // Every destination holds the same manifest; the furthest-along copy
            // is the one that describes the most durable progress.
            guard let manifest = entries.map(\.manifest).max(by: { progress($0) < progress($1) }) else { continue }
            let destinationAccesses = transferDestinationRoots[transferID] ?? [:]
            let assigned = assignRoots(manifest: manifest, entries: entries, accesses: destinationAccesses)
            transfers.append(RecoverableTransfer(
                manifest: manifest,
                source: recoveredSource(manifest: manifest, access: sourceRoots[transferID]),
                destinations: manifest.destinations.map { plan in
                    recoveredDestination(plan: plan, manifest: manifest,
                                         access: destinationAccesses[plan.id],
                                         discovered: assigned[plan.id])
                }))
        }
        return RecoveryScan(
            transfers: transfers.sorted { $0.manifest.createdAt > $1.manifest.createdAt },
            unreadable: unreadable.sorted { $0.manifestURL.path < $1.manifestURL.path })
    }

    /// Rebuilds the plan needed to resume. Destination root paths and the source
    /// root live only in bookmarks, never in the portable manifest, so they are
    /// supplied here and checked against the recorded volume identities before
    /// any of them is written to.
    public func resumePlan(for transfer: RecoverableTransfer) throws -> TransferPlan {
        guard let sourceRoot = transfer.source.root else { throw RecoveryError.sourceUnavailable }
        guard transfer.source.match.allowsResume else {
            throw RecoveryError.volumeMismatch(label: transfer.source.recordedVolume.displayName)
        }
        var destinations: [DestinationPlan] = []
        for recorded in transfer.manifest.destinations {
            guard let found = transfer.destinations.first(where: { $0.id == recorded.id }),
                  let root = found.root else {
                throw RecoveryError.destinationUnavailable(label: recorded.label)
            }
            guard found.match.allowsResume else { throw RecoveryError.volumeMismatch(label: recorded.label) }
            destinations.append(DestinationPlan(id: recorded.id, label: recorded.label,
                                                rootPath: root.path, volume: recorded.volume))
        }
        // Rebuilt from the manifest so the resumed plan describes the transfer
        // that was interrupted, not a fresh scan of whatever is on the card now.
        let files = transfer.manifest.files.map {
            SourceFile(relativePath: $0.relativeSourcePath, byteCount: $0.byteCount,
                       creationDate: $0.creationDate, modificationDate: $0.modificationDate,
                       mediaKind: $0.mediaKind)
        }
        return TransferPlan(id: transfer.manifest.transferID, name: transfer.manifest.transferName,
                            mode: transfer.manifest.mode, sourceRootPath: sourceRoot.path,
                            sourceVolume: transfer.manifest.source, files: files, destinations: destinations)
    }

    /// The manifest URL to resume from: the copy that recorded the most progress.
    public func resumeManifestURL(for transfer: RecoverableTransfer) throws -> URL {
        guard let url = transfer.destinations.compactMap(\.manifestURL).first else {
            throw RecoveryError.manifestUnreadable(transfer.name)
        }
        return url
    }

    /// A read-only rendering of the durable record. Opens nothing for writing and
    /// leaves every timestamp on disk untouched.
    public nonisolated func inspect(_ transfer: RecoverableTransfer) -> RecoveryInspection {
        let labels = Dictionary(uniqueKeysWithValues: transfer.manifest.destinations.map { ($0.id, $0.label) })
        return RecoveryInspection(
            transferID: transfer.manifest.transferID,
            transferName: transfer.manifest.transferName,
            manifestURLs: transfer.destinations.compactMap(\.manifestURL),
            files: transfer.manifest.files.map { file in
                InspectedFile(
                    relativePath: file.relativeSourcePath, byteCount: file.byteCount,
                    mediaKind: file.mediaKind, sourceChecksum: file.sourceChecksum,
                    destinations: transfer.manifest.destinations.map { plan in
                        let result = file.destinations[plan.id] ?? DestinationFileResult()
                        return InspectedDestinationResult(
                            destinationID: plan.id, label: labels[plan.id] ?? plan.label,
                            copyState: result.copyState, verification: result.verification,
                            conflict: result.conflict, error: result.error)
                    })
            })
    }

    /// Lists exactly what abandoning would delete. Only artifacts this transfer
    /// recorded as unfinished qualify: a verified file, a file CardVault paused
    /// on, and anything CardVault did not write are all left alone.
    public nonisolated func abandonPlan(for transfer: RecoverableTransfer) -> AbandonPlan {
        var removable: [URL] = []
        var descriptions: [String] = []
        var refused: [String] = []
        var verified = 0
        var conflicted = 0
        for file in transfer.manifest.files {
            for destination in transfer.destinations {
                guard let result = file.destinations[destination.id] else { continue }
                if result.verification == .verified { verified += 1; continue }
                if result.copyState == .conflicted { conflicted += 1; continue }
                guard result.copyState == .copying || result.copyState == .failed,
                      let staging = destination.stagingRoot else { continue }
                // The `copyState` that authorises this deletion comes from the
                // same document as the path, so the path is checked against the
                // tree rather than trusted along with it.
                guard let url = TransferLayout.containedURL(
                    relativePath: file.relativeDestinationPath,
                    under: TransferLayout.originalsRoot(inStaging: staging)) else {
                    refused.append("\(destination.label) — \(file.relativeDestinationPath)")
                    continue
                }
                removable.append(url)
                descriptions.append("\(destination.label) — \(file.relativeDestinationPath)")
            }
        }
        return AbandonPlan(removableIncompleteArtifacts: removable, removableDescriptions: descriptions,
                           verifiedFilesKept: verified, conflictedFilesKept: conflicted,
                           manifestsKept: transfer.destinations.compactMap(\.manifestURL),
                           refusedPaths: refused)
    }

    /// Marks the transfer abandoned so recovery stops offering it. The source is
    /// never touched. Verified files, paused files, unrelated content, and the
    /// manifests themselves all stay. Partial artifacts are removed only when the
    /// caller explicitly asks, and only the ones `abandonPlan` listed.
    public func abandon(_ transfer: RecoverableTransfer,
                        removingIncompleteArtifacts: Bool) async -> AbandonOutcome {
        var removed: [URL] = []
        var failures: [String] = []
        let plan = abandonPlan(for: transfer)
        if removingIncompleteArtifacts {
            for url in plan.removableIncompleteArtifacts {
                guard fileManager.fileExists(atPath: url.path) else { continue }
                do { try fileManager.removeItem(at: url); removed.append(url) }
                catch { failures.append("\(url.lastPathComponent): \(describe(error))") }
            }
        }
        var marked: [URL] = []
        var manifest = transfer.manifest
        manifest.abandonedAt = now()
        manifest.warnings.append("Abandoned by the user. Files already verified were left in place.")
        for url in transfer.destinations.compactMap(\.manifestURL) {
            do { try await manifestStore.save(manifest, to: url); marked.append(url) }
            catch { failures.append("\(url.lastPathComponent): \(describe(error))") }
        }
        return AbandonOutcome(removedArtifacts: removed, failures: failures, manifestsMarked: marked)
    }

    // MARK: - Helpers

    private func stagingDirectories(in root: URL) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants])) ?? []
        return children.filter { url in
            TransferLayout.transferID(fromStagingName: url.lastPathComponent) != nil
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.sorted { $0.path < $1.path }
    }

    private func recoveredSource(manifest: TransferManifest, access: SecurityScopedAccess?) -> RecoveredSource {
        guard let access else {
            return RecoveredSource(recordedVolume: manifest.source, root: nil,
                                   match: .unavailable, bookmarkWasStale: false)
        }
        return RecoveredSource(recordedVolume: manifest.source, root: access.url,
                               match: match(recorded: manifest.source, at: access.url, assumeRemovable: true),
                               bookmarkWasStale: access.wasStale)
    }

    private func recoveredDestination(plan: DestinationPlan, manifest: TransferManifest,
                                      access: SecurityScopedAccess?,
                                      discovered: (root: URL, staging: URL)?)
        -> RecoveredDestination {
        let counts = manifest.files.reduce(into: (copied: 0, verified: 0, conflicted: 0)) { totals, file in
            guard let result = file.destinations[plan.id] else { return }
            if result.copyState == .copied || result.copyState == .skipped { totals.copied += 1 }
            if result.verification == .verified { totals.verified += 1 }
            if result.copyState == .conflicted { totals.conflicted += 1 }
        }
        let root = access?.url ?? discovered?.root
        let staging = root.map { TransferLayout(manifest: manifest).stagingRoot(in: $0) } ?? discovered?.staging
        return RecoveredDestination(
            id: plan.id, label: plan.label, recordedVolume: plan.volume, root: root,
            stagingRoot: staging,
            manifestURL: staging.map { TransferLayout.manifestURL(inStaging: $0) },
            match: root.map { match(recorded: plan.volume, at: $0) } ?? .unavailable,
            bookmarkWasStale: access?.wasStale ?? false,
            copiedFiles: counts.copied, verifiedFiles: counts.verified, conflictedFiles: counts.conflicted)
    }

    private func match(recorded: VolumeIdentity, at url: URL, assumeRemovable: Bool = false) -> RecoveryVolumeMatch {
        let current = resolver.identity(for: url, defaultName: url.lastPathComponent,
                                        assumeRemovable: assumeRemovable)
        switch recorded.relation(to: current) {
        case .sameVolume: return .matched
        // A different partition of the same physical device is still a different
        // volume, so it is a mismatch rather than a match.
        case .sameDevice, .distinct: return .mismatched
        case .indeterminate: return .indeterminate
        }
    }

    /// Ties each recorded destination to the tree it actually wrote to. The
    /// manifest deliberately carries no mount paths, so the tie is made by
    /// bookmark first and by stable volume identity second. A drive that moved
    /// to a new mount point still matches; a different drive does not, however
    /// its label reads.
    private func assignRoots(manifest: TransferManifest,
                             entries: [(root: URL, staging: URL, manifest: TransferManifest)],
                             accesses: [UUID: SecurityScopedAccess]) -> [UUID: (root: URL, staging: URL)] {
        var remaining = entries
        var assigned: [UUID: (root: URL, staging: URL)] = [:]

        for plan in manifest.destinations {
            guard let access = accesses[plan.id] else { continue }
            if let index = remaining.firstIndex(where: {
                $0.root.standardizedFileURL == access.url.standardizedFileURL
            }) {
                assigned[plan.id] = (remaining[index].root, remaining[index].staging)
                remaining.remove(at: index)
            }
        }
        // Volume identity cannot separate two folders on one drive: both
        // destinations record the same identity, so a tree that matches one
        // matches the other. Binding either would be a guess, and a wrong guess
        // resumes a destination into another destination's tree. Assign only
        // where the pairing is the single possible one in both directions.
        let ambiguous = manifest.destinations.filter { assigned[$0.id] == nil && accesses[$0.id] == nil }
        for plan in ambiguous {
            let candidates = remaining.indices.filter {
                match(recorded: plan.volume, at: remaining[$0].root) == .matched
            }
            guard candidates.count == 1 else { continue }
            let index = candidates[0]
            let rivals = ambiguous.filter {
                $0.id != plan.id && assigned[$0.id] == nil
                    && match(recorded: $0.volume, at: remaining[index].root) == .matched
            }
            guard rivals.isEmpty else { continue }
            assigned[plan.id] = (remaining[index].root, remaining[index].staging)
            remaining.remove(at: index)
        }
        // A single destination and a single discovered tree can only be each
        // other, even when the volume cannot identify itself.
        let unassigned = manifest.destinations.filter { assigned[$0.id] == nil }
        if unassigned.count == 1, remaining.count == 1 {
            assigned[unassigned[0].id] = (remaining[0].root, remaining[0].staging)
        }
        return assigned
    }

    /// Ranks two copies of one manifest by how much durable progress each records.
    private func progress(_ manifest: TransferManifest) -> Int {
        manifest.files.reduce(0) { total, file in
            total + file.destinations.values.reduce(0) { subtotal, result in
                subtotal + (result.verification == .verified ? 2 : 0)
                    + (result.copyState == .copied || result.copyState == .skipped ? 1 : 0)
            }
        }
    }

    private func dedupe(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private nonisolated func isUnsupportedSchema(_ error: Error) -> Bool {
        if case ManifestError.unsupportedSchema = error { return true }
        return false
    }

    private nonisolated func describe(_ error: Error) -> String {
        switch error {
        case ManifestError.unsupportedSchema(let version):
            "The manifest uses schema version \(version), which this version of CardVault cannot read."
        case ManifestError.invalidSchema(let version):
            "The manifest declares schema version \(version), which no version of CardVault wrote."
        case ManifestError.unsafePath(let path):
            "The manifest names a file path (\(path)) that leads outside the transfer's own folder, "
                + "so this record cannot be trusted and nothing was acted on."
        case ManifestError.noValidManifest:
            "No readable manifest was found for this transfer."
        default:
            (error as? LocalizedError)?.errorDescription ?? "The manifest could not be decoded."
        }
    }
}
