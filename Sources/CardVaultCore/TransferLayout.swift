import Foundation

/// The on-disk shape of a transfer's destination tree. Recovery has to find the
/// very directories the coordinator created, so both derive them from here
/// rather than each spelling the convention out for themselves.
public struct TransferLayout: Sendable, Hashable {
    /// Marks a directory as an unfinished CardVault transfer. The leading dot
    /// keeps staging out of the user's way; the suffix is the transfer UUID, so
    /// two runs of the same card never collide.
    public static let incompleteMarker = "cardvault-incomplete"
    public static let manifestRelativePath = ".cardvault/transfer-manifest.json"
    public static let originalsFolderName = "Originals"

    public let transferID: UUID
    public let transferName: String

    public init(transferID: UUID, transferName: String) {
        self.transferID = transferID
        self.transferName = transferName
    }

    public init(manifest: TransferManifest) {
        self.init(transferID: manifest.transferID, transferName: manifest.transferName)
    }

    public init(plan: TransferPlan) {
        self.init(transferID: plan.id, transferName: plan.name)
    }

    /// A transfer name reaches the file system here, so the one separator that
    /// would silently create a subdirectory is folded away.
    public var safeName: String { transferName.replacingOccurrences(of: "/", with: "-") }

    public var stagingFolderName: String { ".\(safeName).\(Self.incompleteMarker)-\(transferID.uuidString)" }

    public func stagingRoot(in destinationRoot: URL) -> URL {
        destinationRoot.appending(path: stagingFolderName, directoryHint: .isDirectory)
    }

    public func finalRoot(in destinationRoot: URL) -> URL {
        destinationRoot.appending(path: safeName, directoryHint: .isDirectory)
    }

    public static func originalsRoot(inStaging staging: URL) -> URL {
        staging.appending(path: originalsFolderName, directoryHint: .isDirectory)
    }

    public static func manifestURL(inStaging staging: URL) -> URL {
        staging.appending(path: manifestRelativePath)
    }

    /// Recovers the transfer UUID from a staging directory name, so a scan can
    /// tell a CardVault artifact from any other dot-directory before it reads
    /// anything. Returns nil for names this build did not write.
    public static func transferID(fromStagingName name: String) -> UUID? {
        guard let range = name.range(of: "\(incompleteMarker)-", options: .backwards) else { return nil }
        return UUID(uuidString: String(name[range.upperBound...]))
    }
}
