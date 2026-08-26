import Foundation

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
    private let tuning: TransferTuning
    private let now: @Sendable () -> Date

    /// Precise counters live here, on the coordinator. Only throttled snapshots
    /// ever reach the progress handler, so a fast drive cannot flood the caller.
    private var aggregator: ProgressAggregator?
    private var progressHandler: ProgressHandler?

    public init(fileSystem: LocalFileSystem = LocalFileSystem(), manifestStore: ManifestStore = ManifestStore(),
                tuning: TransferTuning = .default,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileSystem = fileSystem
        self.manifestStore = manifestStore
        self.tuning = tuning
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
        progressHandler = progress
        defer { progressHandler = nil; aggregator = nil }
        manifest.state = .copying
        try await persist(manifest, locations: locations)

        do {
            try await copy(plan: plan, manifest: &manifest, locations: locations)
            manifest.state = .copyComplete
            try await persist(manifest, locations: locations)
            manifest.state = .verifying
            try await persist(manifest, locations: locations)
            try await verify(plan: plan, manifest: &manifest, locations: locations)
            return try await finish(plan: plan, manifest: &manifest, locations: locations)
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

    // MARK: - Progress

    /// Work bytes for one phase: every pass over a file's bytes counts once, so
    /// the bar, the rate, and the estimate describe the same quantity.
    private func workBytes(_ plan: TransferPlan, passes: Int) -> Int64 {
        plan.totalBytes * Int64(max(0, passes))
    }

    private func beginPhase(_ phase: TransferProgress.Phase, totalFiles: Int, totalBytes: Int64) {
        aggregator = ProgressAggregator(phase: phase, totalFiles: totalFiles, totalBytes: totalBytes,
                                        tuning: tuning, startedAt: now())
    }

    /// Called from the file system for every chunk. Cheap, and never touches the
    /// main actor unless a throttling threshold has been reached.
    private func recordBytes(_ delta: Int64) async {
        guard var current = aggregator else { return }
        let snapshot = current.record(bytes: delta, at: now())
        aggregator = current
        if let snapshot { await progressHandler?(snapshot) }
    }

    private func beginFile(_ relativePath: String?) async {
        guard var current = aggregator else { return }
        let snapshot = current.beginFile(relativePath, at: now())
        aggregator = current
        if let snapshot { await progressHandler?(snapshot) }
    }

    private func completeFile() async {
        guard var current = aggregator else { return }
        let snapshot = current.completeFile(at: now())
        aggregator = current
        if let snapshot { await progressHandler?(snapshot) }
    }

    /// Publishes the final state of a phase unconditionally.
    private func flushPhase(currentRelativePath: String?? = nil) async {
        guard var current = aggregator else { return }
        let snapshot = current.flush(at: now(), currentRelativePath: currentRelativePath)
        aggregator = current
        await progressHandler?(snapshot)
    }

    private var byteHandler: LocalFileSystem.ByteHandler {
        { [weak self] delta in await self?.recordBytes(delta) }
    }

    // MARK: - Copy

    private func copy(plan: TransferPlan, manifest: inout TransferManifest, locations: [Location]) async throws {
        // One source hash pass plus one write pass per destination.
        beginPhase(.copying, totalFiles: manifest.files.count,
                   totalBytes: workBytes(plan, passes: 1 + locations.count))
        let onBytes = byteHandler
        for index in manifest.files.indices {
            try Task.checkCancellation()
            let file = manifest.files[index]
            await beginFile(file.relativeSourcePath)
            let source = URL(filePath: plan.sourceRootPath).appending(path: file.relativeSourcePath)
            let sourceSize = try await fileSystem.fileSize(source)
            guard sourceSize == file.byteCount else { throw FileSystemError.sourceChanged(file.relativeSourcePath) }
            manifest.files[index].sourceChecksum = try await fileSystem.checksum(source, expectedSize: file.byteCount,
                                                                                onBytes: onBytes)
            // Destinations are written one at a time: concurrent writes would mean
            // concurrent reads of the same removable source.
            for location in locations {
                let result = manifest.files[index].destinations[location.destination.id]
                guard result?.copyState != .copied && result?.verification != .verified else {
                    // Resumed work still counts toward the phase so the bar stays honest.
                    await recordBytes(file.byteCount)
                    continue
                }
                let destination = location.originalsRoot.appending(path: file.relativeDestinationPath)
                if await fileSystem.exists(destination) {
                    if result?.copyState == .copied { await recordBytes(file.byteCount); continue }
                    if result?.copyState == .copying || result?.copyState == .failed {
                        try await fileSystem.removeIncompleteFile(destination)
                    } else {
                        throw FileSystemError.existingConflict(file.relativeDestinationPath)
                    }
                }
                manifest.files[index].destinations[location.destination.id]?.copyState = .copying
                try await persist(manifest, locations: locations)
                do {
                    try await fileSystem.copyExclusive(from: source, to: destination,
                                                       expectedSize: file.byteCount, onBytes: onBytes)
                    manifest.files[index].destinations[location.destination.id]?.copyState = .copied
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    manifest.files[index].destinations[location.destination.id]?.copyState = .failed
                    manifest.files[index].destinations[location.destination.id]?.error = String(describing: error)
                }
                try await persist(manifest, locations: locations)
            }
            await completeFile()
        }
        // A complete copy phase is not a successful transfer; verification follows.
        await flushPhase(currentRelativePath: .some(nil))
    }

    // MARK: - Verify

    private struct VerificationJob: Sendable {
        let destinationID: UUID
        let url: URL
    }

    private struct VerificationOutcomeRecord: Sendable {
        let destinationID: UUID
        let checksum: String?
        let error: String?
    }

    private func verify(plan: TransferPlan, manifest: inout TransferManifest, locations: [Location]) async throws {
        beginPhase(.verifying, totalFiles: manifest.files.count,
                   totalBytes: workBytes(plan, passes: locations.count))
        let readers = try await makeVerificationReaders(locations: locations)
        for index in manifest.files.indices {
            try Task.checkCancellation()
            let file = manifest.files[index]
            await beginFile(file.relativeSourcePath)
            var jobs: [VerificationJob] = []
            for location in locations {
                guard manifest.files[index].destinations[location.destination.id]?.copyState == .copied else {
                    await recordBytes(file.byteCount)
                    continue
                }
                jobs.append(.init(destinationID: location.destination.id,
                                  url: location.originalsRoot.appending(path: file.relativeDestinationPath)))
            }
            let records = try await checksums(for: jobs, expectedSize: file.byteCount, readers: readers)
            for record in records {
                if let checksum = record.checksum {
                    manifest.files[index].destinations[record.destinationID]?.destinationChecksum = checksum
                    manifest.files[index].destinations[record.destinationID]?.verification =
                        checksum == file.sourceChecksum ? .verified : .mismatch
                } else {
                    manifest.files[index].destinations[record.destinationID]?.verification = .failed
                    manifest.files[index].destinations[record.destinationID]?.error = record.error
                }
                try await persist(manifest, locations: locations)
            }
            await completeFile()
        }
        await flushPhase(currentRelativePath: .some(nil))
    }

    /// One file system actor per destination when bounded concurrency is enabled;
    /// a single shared actor would serialise the reads it is meant to overlap.
    private func makeVerificationReaders(locations: [Location]) async throws -> [UUID: LocalFileSystem] {
        guard tuning.destinationConcurrency > 1, locations.count > 1 else {
            return locations.reduce(into: [:]) { $0[$1.destination.id] = fileSystem }
        }
        var readers: [UUID: LocalFileSystem] = [:]
        for location in locations { readers[location.destination.id] = await fileSystem.makePeer() }
        return readers
    }

    private func checksums(for jobs: [VerificationJob], expectedSize: Int64,
                           readers: [UUID: LocalFileSystem]) async throws -> [VerificationOutcomeRecord] {
        guard !jobs.isEmpty else { return [] }
        let limit = min(tuning.destinationConcurrency, jobs.count)
        let onBytes = byteHandler
        guard limit > 1 else {
            var records: [VerificationOutcomeRecord] = []
            for job in jobs {
                records.append(await checksum(job: job, expectedSize: expectedSize,
                                              reader: readers[job.destinationID] ?? fileSystem, onBytes: onBytes))
            }
            return records
        }
        var records: [VerificationOutcomeRecord] = []
        try await withThrowingTaskGroup(of: VerificationOutcomeRecord.self) { group in
            var next = jobs.startIndex
            func addTask() {
                let job = jobs[next]
                next = jobs.index(after: next)
                let reader = readers[job.destinationID] ?? fileSystem
                group.addTask { await Self.checksum(job: job, expectedSize: expectedSize, reader: reader, onBytes: onBytes) }
            }
            for _ in 0..<limit { addTask() }
            while let record = try await group.next() {
                records.append(record)
                if next < jobs.endIndex { addTask() }
            }
        }
        // Deterministic manifest writes regardless of completion order.
        let order = jobs.map(\.destinationID)
        return records.sorted { (order.firstIndex(of: $0.destinationID) ?? 0) < (order.firstIndex(of: $1.destinationID) ?? 0) }
    }

    private func checksum(job: VerificationJob, expectedSize: Int64, reader: LocalFileSystem,
                          onBytes: @escaping LocalFileSystem.ByteHandler) async -> VerificationOutcomeRecord {
        await Self.checksum(job: job, expectedSize: expectedSize, reader: reader, onBytes: onBytes)
    }

    private static func checksum(job: VerificationJob, expectedSize: Int64, reader: LocalFileSystem,
                                 onBytes: @escaping LocalFileSystem.ByteHandler) async -> VerificationOutcomeRecord {
        do {
            let size = try await reader.fileSize(job.url)
            guard size == expectedSize else { throw FileSystemError.unexpectedEndOfFile(job.url.lastPathComponent) }
            let checksum = try await reader.checksum(job.url, expectedSize: expectedSize, onBytes: onBytes)
            return .init(destinationID: job.destinationID, checksum: checksum, error: nil)
        } catch {
            return .init(destinationID: job.destinationID, checksum: nil, error: String(describing: error))
        }
    }

    // MARK: - Finish

    private func finish(plan: TransferPlan, manifest: inout TransferManifest,
                        locations: [Location]) async throws -> TransferOutcome {
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
        beginPhase(.finalizing, totalFiles: manifest.files.count, totalBytes: workBytes(plan, passes: 1))
        await recordBytes(plan.totalBytes)
        await flushPhase(currentRelativePath: .some(nil))
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
