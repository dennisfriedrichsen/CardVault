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

public enum BookmarkError: Error, Sendable { case stale, accessDenied }

public actor SecurityScopedBookmarkStore {
    private let storageURL: URL
    private var bookmarks: [String: Data] = [:]

    public init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) { bookmarks = decoded }
    }

    public func save(url: URL, key: String) throws {
        bookmarks[key] = try url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        try persist()
    }

    public func resolve(key: String) throws -> SecurityScopedAccess {
        guard let data = bookmarks[key] else { throw BookmarkError.accessDenied }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale { throw BookmarkError.stale }
        return try SecurityScopedAccess(url: url)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(bookmarks).write(to: storageURL, options: .atomic)
    }
}

public final class SecurityScopedAccess: @unchecked Sendable {
    public let url: URL
    private let didStart: Bool
    public init(url: URL) throws {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
        guard didStart else { throw BookmarkError.accessDenied }
    }
    deinit { if didStart { url.stopAccessingSecurityScopedResource() } }
}
