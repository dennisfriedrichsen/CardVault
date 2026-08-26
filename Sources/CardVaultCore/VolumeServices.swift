import Foundation

public struct MountedVolume: Sendable, Identifiable {
    public var id: String { identity.resourceIdentifier ?? url.path }
    public let url: URL
    public let identity: VolumeIdentity
}

public actor VolumeDiscoveryService {
    private let resolver: VolumeIdentityResolver

    public init(resolver: VolumeIdentityResolver = VolumeIdentityResolver(provider: DiskArbitrationTopologyProvider())) {
        self.resolver = resolver
    }

    public func mountedVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey,
                                      .volumeIsLocalKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.map { url in
            MountedVolume(url: url, identity: resolver.identity(for: url, defaultName: url.lastPathComponent))
        }.sorted { $0.identity.displayName.localizedStandardCompare($1.identity.displayName) == .orderedAscending }
    }
}

public enum BookmarkError: Error, Sendable { case stale, accessDenied, unknownKey }

/// Bookmark keys CardVault stores. The per-transfer keys are what make relaunch
/// recovery possible: a transfer's own roots have to be reachable months later,
/// after the last-used selections have moved on to other cards and drives.
public enum BookmarkKey {
    public static let lastSource = "last-source"
    public static let primary = "primary"
    public static let backup = "backup"
    public static let transferPrefix = "transfer/"

    public static func source(transferID: UUID) -> String {
        "\(transferPrefix)\(transferID.uuidString)/source"
    }

    public static func destination(transferID: UUID, destinationID: UUID) -> String {
        "\(transferPrefix)\(transferID.uuidString)/destination/\(destinationID.uuidString)"
    }

    public static func transferID(fromKey key: String) -> UUID? {
        guard key.hasPrefix(transferPrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(transferPrefix.count).prefix(while: { $0 != "/" })))
    }
}

public actor SecurityScopedBookmarkStore {
    private let storageURL: URL
    private var bookmarks: [String: Data] = [:]

    public init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) { bookmarks = decoded }
    }

    public var keys: [String] { bookmarks.keys.sorted() }

    public func keys(withPrefix prefix: String) -> [String] {
        bookmarks.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    public func save(url: URL, key: String) throws {
        bookmarks[key] = try url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        try persist()
    }

    public func remove(key: String) throws {
        bookmarks[key] = nil
        try persist()
    }

    public func removeAll(withPrefix prefix: String) throws {
        for key in bookmarks.keys where key.hasPrefix(prefix) { bookmarks[key] = nil }
        try persist()
    }

    /// A stale bookmark still resolves: the volume moved or was remounted, not
    /// lost. Discarding it would strand an interrupted transfer on a drive the
    /// user already granted access to, so the resolved URL is kept and the
    /// bookmark is rewritten in place. Callers are told it happened because a
    /// stale resolution is worth confirming against volume identity.
    public func resolve(key: String) throws -> SecurityScopedAccess {
        guard let data = bookmarks[key] else { throw BookmarkError.unknownKey }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let access = try SecurityScopedAccess(url: url, wasStale: stale)
        if stale, let renewed = try? url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[key] = renewed
            try? persist()
        }
        return access
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(bookmarks).write(to: storageURL, options: .atomic)
    }
}

public final class SecurityScopedAccess: @unchecked Sendable {
    public let url: URL
    /// True when the bookmark had to be renewed to resolve. The URL is good, but
    /// the volume behind it should be confirmed before anything is written.
    public let wasStale: Bool
    private let didStart: Bool

    private init(url: URL, wasStale: Bool, didStart: Bool) {
        self.url = url
        self.wasStale = wasStale
        self.didStart = didStart
    }

    public convenience init(url: URL, wasStale: Bool = false) throws {
        guard url.startAccessingSecurityScopedResource() else { throw BookmarkError.accessDenied }
        self.init(url: url, wasStale: wasStale, didStart: true)
    }

    /// For a URL that needs no security scope to reach — one already inside the
    /// app's container, or a path in a build that is not sandboxed. Claims no
    /// scope, so it releases none.
    public static func unscoped(_ url: URL, wasStale: Bool = false) -> SecurityScopedAccess {
        SecurityScopedAccess(url: url, wasStale: wasStale, didStart: false)
    }

    deinit { if didStart { url.stopAccessingSecurityScopedResource() } }
}
