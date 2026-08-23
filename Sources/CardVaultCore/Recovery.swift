import Foundation

public struct RecoverableTransfer: Sendable, Identifiable {
    public var id: UUID { manifest.transferID }
    public let manifest: TransferManifest
    public let manifestURL: URL
}

public actor RecoveryCoordinator {
    private let manifestStore: ManifestStore
    public init(manifestStore: ManifestStore = ManifestStore()) { self.manifestStore = manifestStore }

    public func discover(in roots: [URL]) async -> [RecoverableTransfer] {
        var transfers: [RecoverableTransfer] = []
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: []
            ) else { continue }
            for child in children where child.lastPathComponent.contains("cardvault-incomplete") {
                let url = child.appending(path: ".cardvault/transfer-manifest.json")
                if let manifest = try? await manifestStore.load(from: url), manifest.state != .safeToEject {
                    transfers.append(.init(manifest: manifest, manifestURL: url))
                }
            }
        }
        return transfers
    }
}
