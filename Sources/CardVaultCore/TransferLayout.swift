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

    /// Joins a relative path from a manifest onto a root, and hands it back only
    /// when the result stays inside that root.
    ///
    /// The manifest is a document on removable media: anything with access to
    /// the drive can write it, and the paths in it are deleted from and written
    /// to. `URL.appending(path:)` does not resolve `..`, and the file system
    /// resolves it at syscall time, so a component that walks out of the tree
    /// survives all the way to the operation unless it is checked here.
    public static func containedURL(relativePath: String, under root: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else { return nil }
        let base = root.standardizedFileURL
        let candidate = root.appending(path: relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        // Symlinks are resolved on both sides identically, so a link planted in
        // the staging tree cannot point the copy out of it either.
        guard candidate.resolvingSymlinksInPath().path
            .hasPrefix(base.resolvingSymlinksInPath().path + "/") else { return nil }
        return candidate
    }

    /// Recovers the transfer UUID from a staging directory name, so a scan can
    /// tell a CardVault artifact from any other dot-directory before it reads
    /// anything. Returns nil for names this build did not write.
    public static func transferID(fromStagingName name: String) -> UUID? {
        guard let range = name.range(of: "\(incompleteMarker)-", options: .backwards) else { return nil }
        return UUID(uuidString: String(name[range.upperBound...]))
    }
}
