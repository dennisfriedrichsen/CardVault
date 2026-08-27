import Foundation

/// How a file that already exists at a destination path relates to the file
/// CardVault is about to write there.
///
/// Classification never relies on a matching name and byte count. Every answer
/// that lets CardVault skip a copy is backed by a SHA-256 read of the bytes
/// actually on disk, and every answer that cannot be established that way stops
/// the transfer instead of overwriting or inventing a filename.
public enum ConflictClassification: String, Codable, Sendable, CaseIterable {
    /// This transfer's own manifest records the file as verified, and the bytes
    /// on disk still hash to the recorded value.
    case verifiedByCurrentManifest
    /// A different CardVault manifest this build can read records the same
    /// relative path as verified with our source checksum, confirmed by rereading.
    case verifiedByCompatibleManifest
    /// No CardVault record covers the file, but its bytes hash to the source.
    case contentIdentical
    /// CardVault recorded this artifact as unfinished, so it is ours to replace.
    case incompletePriorCopy
    /// A CardVault record ties this relative path to different content.
    case differentContent
    /// No CardVault record covers the file and its content is not the source's.
    case unrelatedFile
    /// The evidence disagrees with itself, or the file could not be read.
    case ambiguous

    /// The existing file already satisfies the transfer; copying again would be
    /// redundant work rather than a decision for the user.
    public var isSatisfied: Bool {
        switch self {
        case .verifiedByCurrentManifest, .verifiedByCompatibleManifest, .contentIdentical: true
        case .incompletePriorCopy, .differentContent, .unrelatedFile, .ambiguous: false
        }
    }

    /// CardVault may delete the existing file and copy again. Only an artifact
    /// CardVault itself recorded as unfinished qualifies.
    public var isReplaceable: Bool { self == .incompletePriorCopy }

    /// The transfer must pause and ask. These are never overwritten, and are
    /// never resolved by writing to a different filename.
    public var requiresAttention: Bool { !isSatisfied && !isReplaceable }

    public var title: String {
        switch self {
        case .verifiedByCurrentManifest: "Already verified by this transfer"
        case .verifiedByCompatibleManifest: "Already verified by another CardVault transfer"
        case .contentIdentical: "Identical content already present"
        case .incompletePriorCopy: "Incomplete earlier copy"
        case .differentContent: "Different content at the same path"
        case .unrelatedFile: "Unrelated existing file"
        case .ambiguous: "Needs attention"
        }
    }
}

/// One unresolved conflict, surfaced so the user can decide. Carries the
/// relative path only — full destination paths and bookmark data stay out of
/// anything that may be logged or displayed at a distance from the drive.
public struct DestinationConflict: Sendable, Identifiable, Equatable {
    public var id: String { "\(destinationID.uuidString):\(relativePath)" }
    public let destinationID: UUID
    public let destinationLabel: String
    public let relativePath: String
    public let classification: ConflictClassification
    public let existingByteCount: Int64?
    public let explanation: String

    public init(destinationID: UUID, destinationLabel: String, relativePath: String,
                classification: ConflictClassification, existingByteCount: Int64?, explanation: String) {
        self.destinationID = destinationID
        self.destinationLabel = destinationLabel
        self.relativePath = relativePath
        self.classification = classification
        self.existingByteCount = existingByteCount
        self.explanation = explanation
    }
}

/// Verified file records read from other CardVault manifests already present on
/// a destination. Only manifests whose schema this build supports are consulted,
/// and only their files that at least one destination verified.
public struct CompatibleManifestIndex: Sendable {
    public struct Record: Sendable, Equatable {
        public let transferID: UUID
        public let transferName: String
        /// The source SHA-256 the other transfer recorded. Source checksums are
        /// independent of which tree a copy landed in, so they are the only field
        /// comparable across manifests.
        public let sourceChecksum: String
        public let byteCount: Int64
    }

    private let records: [String: Record]

    public init(records: [String: Record] = [:]) { self.records = records }

    public subscript(relativePath: String) -> Record? {
        // APFS and HFS+ hand back decomposed names where exFAT hands back
        // precomposed ones, so a lookup that misses is retried in both forms.
        records[relativePath]
            ?? records[relativePath.precomposedStringWithCanonicalMapping]
            ?? records[relativePath.decomposedStringWithCanonicalMapping]
    }

    public var isEmpty: Bool { records.isEmpty }

    /// Loads every readable CardVault manifest under `searchRoots`, skipping the
    /// transfer identified by `excluding`. Unreadable or future-schema manifests
    /// are ignored rather than trusted: an unknown record must never be the
    /// reason a file is skipped.
    public static func load(searchRoots: [URL], excluding currentTransferID: UUID,
                            store: ManifestStore = ManifestStore()) async -> CompatibleManifestIndex {
        var records: [String: Record] = [:]
        for root in manifestURLs(in: searchRoots) {
            guard let manifest = try? await store.load(from: root),
                  manifest.schemaVersion <= TransferManifest.currentSchemaVersion,
                  manifest.transferID != currentTransferID else { continue }
            for file in manifest.files {
                guard let checksum = file.sourceChecksum,
                      file.destinations.values.contains(where: { $0.verification == .verified }) else { continue }
                let record = Record(transferID: manifest.transferID, transferName: manifest.transferName,
                                    sourceChecksum: checksum, byteCount: file.byteCount)
                // A path two manifests disagree about proves nothing; drop it so
                // the classifier falls back to reading the bytes.
                if let existing = records[file.relativeDestinationPath], existing.sourceChecksum != checksum {
                    records[file.relativeDestinationPath] = nil
                } else {
                    records[file.relativeDestinationPath] = record
                }
            }
        }
        return CompatibleManifestIndex(records: records)
    }

    private static func manifestURLs(in searchRoots: [URL]) -> [URL] {
        let manager = FileManager.default
        var urls: [URL] = []
        for root in searchRoots {
            let direct = root.appending(path: TransferLayout.manifestRelativePath)
            if manager.fileExists(atPath: direct.path) { urls.append(direct) }
            // Immediate children only. A destination drive may hold many past
            // transfers; it must never cost a full recursive walk to find them.
            let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsPackageDescendants])) ?? []
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let candidate = child.appending(path: TransferLayout.manifestRelativePath)
                if manager.fileExists(atPath: candidate.path) { urls.append(candidate) }
            }
        }
        return urls
    }
}

/// Everything known about a destination path before its bytes are read.
public struct ConflictEvidence: Sendable {
    public let relativePath: String
    public let expectedByteCount: Int64
    /// The SHA-256 of the source file. Classification cannot proceed without it.
    public let sourceChecksum: String?
    /// What this transfer's own manifest last recorded for this destination.
    public let currentResult: DestinationFileResult?
    public let compatibleRecord: CompatibleManifestIndex.Record?

    public init(relativePath: String, expectedByteCount: Int64, sourceChecksum: String?,
                currentResult: DestinationFileResult?, compatibleRecord: CompatibleManifestIndex.Record?) {
        self.relativePath = relativePath
        self.expectedByteCount = expectedByteCount
        self.sourceChecksum = sourceChecksum
        self.currentResult = currentResult
        self.compatibleRecord = compatibleRecord
    }
}

public struct ConflictAssessment: Sendable, Equatable {
    public let classification: ConflictClassification
    public let existingByteCount: Int64?
    /// The digest actually computed from the bytes on disk, when they could be
    /// read. Recorded durably so a skip is auditable against the source digest.
    public let existingChecksum: String?
    public let explanation: String
}

/// Decides what an existing destination file is, reading its bytes whenever the
/// answer depends on content. The classifier never writes and never deletes.
public struct ConflictClassifier: Sendable {
    public init() {}

    public func assess(existingFileAt url: URL, evidence: ConflictEvidence,
                       fileSystem: LocalFileSystem) async -> ConflictAssessment {
        guard let sourceChecksum = evidence.sourceChecksum else {
            return .init(classification: .ambiguous, existingByteCount: nil, existingChecksum: nil,
                         explanation: "The source checksum is not known yet, so the existing file cannot be classified.")
        }

        // CardVault's own record that it was mid-write outranks anything the
        // bytes could say: a partial artifact is ours to remove and redo.
        if let state = evidence.currentResult?.copyState, state == .copying || state == .failed {
            let size = try? await fileSystem.fileSize(url)
            return .init(classification: .incompletePriorCopy, existingByteCount: size, existingChecksum: nil,
                         explanation: "CardVault recorded this copy as unfinished, so the incomplete artifact is replaced.")
        }

        let size = try? await fileSystem.fileSize(url)
        // Hashed without an expected size: a length mismatch is a classification
        // result here, not a read error.
        guard let observed = try? await fileSystem.checksum(url) else {
            return .init(classification: .ambiguous, existingByteCount: size, existingChecksum: nil,
                         explanation: "The existing file could not be read completely, so it cannot be classified.")
        }

        if let result = evidence.currentResult, result.copyState == .copied || result.verification == .verified {
            if observed == sourceChecksum {
                let alreadyVerified = result.verification == .verified
                    && result.destinationChecksum == observed
                return .init(classification: alreadyVerified ? .verifiedByCurrentManifest : .contentIdentical,
                             existingByteCount: size, existingChecksum: observed,
                             explanation: alreadyVerified
                                ? "This transfer already verified this file and its bytes are unchanged."
                                : "This transfer had finished copying this file; rereading it confirms the source digest.")
            }
            return .init(classification: .ambiguous, existingByteCount: size, existingChecksum: observed,
                         explanation: "This transfer recorded writing this file, but its bytes no longer match the source.")
        }

        if let record = evidence.compatibleRecord {
            guard record.sourceChecksum == sourceChecksum else {
                return .init(classification: .differentContent, existingByteCount: size, existingChecksum: observed,
                             explanation: "Transfer \"\(record.transferName)\" recorded different content at this path.")
            }
            if observed == record.sourceChecksum {
                return .init(classification: .verifiedByCompatibleManifest, existingByteCount: size,
                             existingChecksum: observed,
                             explanation: "Transfer \"\(record.transferName)\" verified this file, and rereading it confirms the source digest.")
            }
            return .init(classification: .ambiguous, existingByteCount: size, existingChecksum: observed,
                         explanation: "Transfer \"\(record.transferName)\" records this file as verified, but its bytes have since changed.")
        }

        if observed == sourceChecksum {
            return .init(classification: .contentIdentical, existingByteCount: size, existingChecksum: observed,
                         explanation: "An existing file at this path has the same SHA-256 as the source.")
        }
        return .init(classification: .unrelatedFile, existingByteCount: size, existingChecksum: observed,
                     explanation: "A file CardVault did not write already exists at this path with different content.")
    }
}
