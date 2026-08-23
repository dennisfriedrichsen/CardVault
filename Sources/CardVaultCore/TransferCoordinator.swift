import Foundation

public struct TransferProgress: Sendable {
    public enum Phase: String, Sendable { case copying, verifying, finalizing }
    public let phase: Phase
    public let completedFiles: Int
    public let totalFiles: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentRelativePath: String?
}

public struct DestinationOutcome: Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let verifiedFiles: Int
    public let failedFiles: Int
    public let finalURL: URL?
    public var isVerified: Bool { failedFiles == 0 }
}

public struct TransferOutcome: Sendable {
    public let transferID: UUID
    public let state: TransferState
    public let destinations: [DestinationOutcome]
    public let safeToEject: Bool
}

public actor TransferCoordinator {
    public typealias ProgressHandler = @Sendable (TransferProgress) async -> Void
    private let fileSystem: LocalFileSystem
    private let manifestStore: ManifestStore
    private let now: @Sendable () -> Date

    public init(fileSystem: LocalFileSystem = LocalFileSystem(), manifestStore: ManifestStore = ManifestStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileSystem = fileSystem
        self.manifestStore = manifestStore
        self.now = now
    }

    public func execute(plan: TransferPlan, progress: ProgressHandler? = nil) async throws -> TransferOutcome {
        var manifest = TransferManifest(plan: plan, now: now())
        let locations = destinationLocations(plan)
        try await prepare(locations: locations)
        manifest.startedAt = now()
        return try await run(plan: plan, manifest: &manifest, locations: locations, progress: progress)
    }

    public func resume(plan: TransferPlan, manifestURL: URL,
                       progress: ProgressHandler? = nil) async throws -> TransferOutcome {
        var manifest = try await manifestStore.load(from: manifestURL)
        guard manifest.transferID == plan.id else { throw ManifestError.noValidManifest }
        let locations = destinationLocations(plan)
        try await prepare(locations: locations)
        return try await run(plan: plan, manifest: &manifest, locations: locations, progress: progress)
    }

    private func run(plan: TransferPlan, manifest: inout TransferManifest, locations: [Location],
                     progress: ProgressHandler?) async throws -> TransferOutcome {
        manifest.state = .copying
        try await persist(manifest, locations: locations)

        do {
            try await copy(plan: plan, manifest: &manifest, locations: locations, progress: progress)
            manifest.state = .copyComplete
            try await persist(manifest, locations: locations)
            manifest.state = .verifying
            try await persist(manifest, locations: locations)
            try await verify(plan: plan, manifest: &manifest, locations: locations, progress: progress)
            return try await finish(plan: plan, manifest: &manifest, locations: locations, progress: progress)
        } catch is CancellationError {
            manifest.state = .cancelled
            manifest.errors.append("Transfer cancelled at a safe file boundary.")
            try? await persist(manifest, locations: locations)
            throw CancellationError()
        } catch {
            manifest.state = .interrupted
            manifest.errors.append(String(describing: error))
            try? await persist(manifest, locations: locations)
            throw error
        }
    }

    private struct Location: Sendable {
        let destination: DestinationPlan
        let stagingRoot: URL
        let originalsRoot: URL
        let manifestURL: URL
        let finalRoot: URL
    }

    private func destinationLocations(_ plan: TransferPlan) -> [Location] {
        let safeName = plan.name.replacingOccurrences(of: "/", with: "-")
        return plan.destinations.map { destination in
            let parent = URL(filePath: destination.rootPath, directoryHint: .isDirectory)
            let staging = parent.appending(path: ".\(safeName).cardvault-incomplete-\(plan.id.uuidString)", directoryHint: .isDirectory)
            return Location(destination: destination, stagingRoot: staging,
                            originalsRoot: staging.appending(path: "Originals", directoryHint: .isDirectory),
                            manifestURL: staging.appending(path: ".cardvault/transfer-manifest.json"),
                            finalRoot: parent.appending(path: safeName, directoryHint: .isDirectory))
        }
    }

    private func prepare(locations: [Location]) async throws {
        for location in locations {
            if await fileSystem.exists(location.finalRoot) { throw FileSystemError.existingConflict(location.finalRoot.path) }
            try await fileSystem.createDirectory(location.originalsRoot)
        }
    }

    private func persist(_ manifest: TransferManifest, locations: [Location]) async throws {
        for location in locations { try await manifestStore.save(manifest, to: location.manifestURL) }
    }

    private func copy(plan: TransferPlan, manifest: inout TransferManifest, locations: [Location],
                      progress: ProgressHandler?) async throws {
        var completedBytes: Int64 = 0
        for index in manifest.files.indices {
            try Task.checkCancellation()
            let file = manifest.files[index]
            let source = URL(filePath: plan.sourceRootPath).appending(path: file.relativeSourcePath)
            let sourceSize = try await fileSystem.fileSize(source)
            guard sourceSize == file.byteCount else { throw FileSystemError.sourceChanged(file.relativeSourcePath) }
            manifest.files[index].sourceChecksum = try await fileSystem.checksum(source, expectedSize: file.byteCount)
            for location in locations {
                let result = manifest.files[index].destinations[location.destination.id]
                guard result?.copyState != .copied && result?.verification != .verified else { continue }
                let destination = location.originalsRoot.appending(path: file.relativeDestinationPath)
                if await fileSystem.exists(destination) {
                    if result?.copyState == .copied { continue }
                    if result?.copyState == .copying || result?.copyState == .failed {
                        try await fileSystem.removeIncompleteFile(destination)
                    } else {
                        throw FileSystemError.existingConflict(file.relativeDestinationPath)
                    }
                }
                manifest.files[index].destinations[location.destination.id]?.copyState = .copying
                try await persist(manifest, locations: locations)
                do {
                    try await fileSystem.copyExclusive(from: source, to: destination, expectedSize: file.byteCount)
                    manifest.files[index].destinations[location.destination.id]?.copyState = .copied
                } catch {
                    manifest.files[index].destinations[location.destination.id]?.copyState = .failed
                    manifest.files[index].destinations[location.destination.id]?.error = String(describing: error)
                }
                try await persist(manifest, locations: locations)
            }
            completedBytes += file.byteCount
            await progress?(.init(phase: .copying, completedFiles: index + 1, totalFiles: manifest.files.count,
                                  completedBytes: completedBytes, totalBytes: plan.totalBytes,
                                  currentRelativePath: file.relativeSourcePath))
        }
    }

    private func verify(plan: TransferPlan, manifest: inout TransferManifest, locations: [Location],
                        progress: ProgressHandler?) async throws {
        var completedBytes: Int64 = 0
        for index in manifest.files.indices {
            try Task.checkCancellation()
            let file = manifest.files[index]
            for location in locations {
                guard manifest.files[index].destinations[location.destination.id]?.copyState == .copied else { continue }
                let destination = location.originalsRoot.appending(path: file.relativeDestinationPath)
                do {
                    let size = try await fileSystem.fileSize(destination)
                    guard size == file.byteCount else { throw FileSystemError.unexpectedEndOfFile(file.relativeDestinationPath) }
                    let checksum = try await fileSystem.checksum(destination, expectedSize: file.byteCount)
                    manifest.files[index].destinations[location.destination.id]?.destinationChecksum = checksum
                    manifest.files[index].destinations[location.destination.id]?.verification =
                        checksum == file.sourceChecksum ? .verified : .mismatch
                } catch {
                    manifest.files[index].destinations[location.destination.id]?.verification = .failed
                    manifest.files[index].destinations[location.destination.id]?.error = String(describing: error)
                }
                try await persist(manifest, locations: locations)
            }
            completedBytes += file.byteCount
            await progress?(.init(phase: .verifying, completedFiles: index + 1, totalFiles: manifest.files.count,
                                  completedBytes: completedBytes, totalBytes: plan.totalBytes,
                                  currentRelativePath: file.relativeSourcePath))
        }
    }

    private func finish(plan: TransferPlan, manifest: inout TransferManifest, locations: [Location],
                        progress: ProgressHandler?) async throws -> TransferOutcome {
        let destinationResults = locations.map { location -> (Location, Int, Int) in
            let values = manifest.files.compactMap { $0.destinations[location.destination.id] }
            return (location, values.count { $0.verification == .verified }, values.count { $0.verification != .verified })
        }
        let successes = destinationResults.count { $0.2 == 0 }
        manifest.completedAt = now()
        if successes == locations.count {
            manifest.state = .verified
            manifest.verifiedAt = now()
        } else if successes > 0 {
            manifest.state = .partiallySuccessful
        } else {
            manifest.state = .failed
        }
        try await persist(manifest, locations: locations)
        await progress?(.init(phase: .finalizing, completedFiles: manifest.files.count,
                              totalFiles: manifest.files.count, completedBytes: plan.totalBytes,
                              totalBytes: plan.totalBytes, currentRelativePath: nil))
        var outcomes: [DestinationOutcome] = []
        for (location, verified, failed) in destinationResults {
            var finalURL: URL?
            if failed == 0 {
                try await fileSystem.move(location.stagingRoot, to: location.finalRoot)
                finalURL = location.finalRoot
            }
            outcomes.append(.init(id: location.destination.id, label: location.destination.label,
                                  verifiedFiles: verified, failedFiles: failed, finalURL: finalURL))
        }
        // All source FileHandles are scoped and closed before this durable transition.
        manifest.state = .safeToEject
        let finalLocations = locations.map { location in
            guard outcomes.first(where: { $0.id == location.destination.id })?.finalURL != nil else { return location }
            return Location(destination: location.destination, stagingRoot: location.finalRoot,
                            originalsRoot: location.finalRoot.appending(path: "Originals"),
                            manifestURL: location.finalRoot.appending(path: ".cardvault/transfer-manifest.json"),
                            finalRoot: location.finalRoot)
        }
        try await persist(manifest, locations: finalLocations)
        return TransferOutcome(transferID: plan.id,
                               state: successes == locations.count ? .verified : (successes > 0 ? .partiallySuccessful : .failed),
                               destinations: outcomes, safeToEject: true)
    }
}
