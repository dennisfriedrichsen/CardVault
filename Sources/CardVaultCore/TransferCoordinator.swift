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
    /// Destination content CardVault refused to overwrite. Non-empty means the
    /// transfer paused before verification and is waiting on a decision.
    public let conflicts: [DestinationConflict]

    public init(transferID: UUID, state: TransferState, destinations: [DestinationOutcome],
                safeToEject: Bool, conflicts: [DestinationConflict] = []) {
        self.transferID = transferID
        self.state = state
        self.destinations = destinations
        self.safeToEject = safeToEject
        self.conflicts = conflicts
    }

    public var requiresConflictResolution: Bool { !conflicts.isEmpty }
}

public actor TransferCoordinator {
    public typealias ProgressHandler = @Sendable (TransferProgress) async -> Void
    private let fileSystem: LocalFileSystem
    private let manifestStore: ManifestStore
    private let tuning: TransferTuning
    private let classifier: ConflictClassifier
    private let now: @Sendable () -> Date

    /// Destination copies this run itself read back and matched to the source,
    /// as the classifier does when it satisfies a file instead of copying it.
    /// A claim made by an earlier run is not in here, which is what makes it
    /// possible to reread exactly those.
    private var readBackThisRun: Set<ReadBack> = []

    /// Precise counters live here, on the coordinator. Only throttled snapshots
    /// ever reach the progress handler, so a fast drive cannot flood the caller.
    private var aggregator: ProgressAggregator?
    private var progressHandler: ProgressHandler?

    public init(fileSystem: LocalFileSystem = LocalFileSystem(), manifestStore: ManifestStore = ManifestStore(),
                tuning: TransferTuning = .default,
                classifier: ConflictClassifier = ConflictClassifier(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileSystem = fileSystem
        self.manifestStore = manifestStore
        self.tuning = tuning
        self.classifier = classifier
        self.now = now
    }

    public func execute(plan: TransferPlan, progress: ProgressHandler? = nil) async throws -> TransferOutcome {
        var manifest = TransferManifest(plan: plan, now: now())
        let locations = try await prepare(locations: destinationLocations(plan))
        manifest.startedAt = now()
        return try await run(plan: plan, manifest: &manifest, locations: locations, progress: progress)
    }

    public func resume(plan: TransferPlan, manifestURL: URL,
                       progress: ProgressHandler? = nil) async throws -> TransferOutcome {
        var manifest = try await manifestStore.load(from: manifestURL)
        guard manifest.transferID == plan.id else { throw ManifestError.noValidManifest }
        let locations = try await prepare(locations: destinationLocations(plan))
        return try await run(plan: plan, manifest: &manifest, locations: locations, progress: progress)
    }

    private func run(plan: TransferPlan, manifest: inout TransferManifest, locations: [Location],
                     progress: ProgressHandler?) async throws -> TransferOutcome {
        progressHandler = progress
        readBackThisRun = []
        defer { progressHandler = nil; aggregator = nil; readBackThisRun = [] }
        manifest.state = .copying
        try await persist(manifest, locations: locations)

        do {
            let conflicts = try await copy(plan: plan, manifest: &manifest, locations: locations)
            // A conflict is a question for the user, not a failure to push past.
            // Verification and finalisation both wait until it is answered.
            if !conflicts.isEmpty {
                return try await pause(manifest: &manifest, locations: locations, conflicts: conflicts)
            }
            manifest.state = .copyComplete
            try await persist(manifest, locations: locations)
            manifest.state = .verifying
            try await persist(manifest, locations: locations)
            try await verify(plan: plan, manifest: &manifest, locations: locations)
            return try await finish(plan: plan, manifest: &manifest, locations: locations)
        } catch is CancellationError {
            manifest.state = .cancelled
            manifest.errors.append("Transfer cancelled at a safe file boundary.")
            await persistBestEffort(manifest, locations: locations)
            throw CancellationError()
        } catch {
            manifest.state = .interrupted
            manifest.errors.append(String(describing: error))
            await persistBestEffort(manifest, locations: locations)
            throw error
        }
    }

    private struct ReadBack: Hashable, Sendable {
        let fileIndex: Int
        let destinationID: UUID
    }

    private struct Location: Sendable {
        let destination: DestinationPlan
        let stagingRoot: URL
        let originalsRoot: URL
        let manifestURL: URL
        let finalRoot: URL
        /// Measured once, in `prepare`, rather than inferred from the volume
        /// kind: a mount that stores no birth time has to be recognised before
        /// the first file, or every file reports the same shortfall.
        var creationDatesSupported: Bool = false
        /// Slack allowed when a written date is read back, from the destination
        /// file system's own granularity.
        var timestampTolerance: TimeInterval = TimestampTolerance.exact
    }

    private func destinationLocations(_ plan: TransferPlan) -> [Location] {
        let layout = TransferLayout(plan: plan)
        return plan.destinations.map { destination in
            let parent = URL(filePath: destination.rootPath, directoryHint: .isDirectory)
            let staging = layout.stagingRoot(in: parent)
            return Location(destination: destination, stagingRoot: staging,
                            originalsRoot: TransferLayout.originalsRoot(inStaging: staging),
                            manifestURL: TransferLayout.manifestURL(inStaging: staging),
                            finalRoot: layout.finalRoot(in: parent),
                            timestampTolerance: TimestampTolerance.forFileSystem(destination.volume.fileSystem))
        }
    }

    private func prepare(locations: [Location]) async throws -> [Location] {
        var prepared: [Location] = []
        for var location in locations {
            if await fileSystem.exists(location.finalRoot) { throw FileSystemError.existingConflict(location.finalRoot.path) }
            try await fileSystem.createDirectory(location.originalsRoot)
            location.creationDatesSupported = await fileSystem.supportsCreationDates(in: location.originalsRoot)
            prepared.append(location)
        }
        return prepared
    }

    private func persist(_ manifest: TransferManifest, locations: [Location]) async throws {
        for location in locations { try await manifestStore.save(manifest, to: location.manifestURL) }
    }

    /// Error-path persistence, which must never make things worse than the
    /// failure already did. A staging tree that is no longer there is left
    /// alone: finalisation may already have moved it, and recreating it would
    /// offer the user a transfer that has in fact finished. A destination that
    /// cannot take the record keeps the last one it accepted.
    private func persistBestEffort(_ manifest: TransferManifest, locations: [Location]) async {
        for location in locations where await fileSystem.exists(location.stagingRoot) {
            try? await manifestStore.save(manifest, to: location.manifestURL)
        }
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

    private func copy(plan: TransferPlan, manifest: inout TransferManifest,
                      locations: [Location]) async throws -> [DestinationConflict] {
        // One source hash pass plus one write pass per destination.
        beginPhase(.copying, totalFiles: manifest.files.count,
                   totalBytes: workBytes(plan, passes: 1 + locations.count))
        let onBytes = byteHandler
        var indexes: [UUID: CompatibleManifestIndex] = [:]
        for location in locations {
            indexes[location.destination.id] = await CompatibleManifestIndex.load(
                searchRoots: [location.stagingRoot,
                              URL(filePath: location.destination.rootPath, directoryHint: .isDirectory)],
                excluding: manifest.transferID, store: manifestStore)
        }
        var conflicts: [DestinationConflict] = []
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
                    // A file an earlier run copied still needs its dates, or the
                    // archive ends up recording which run copied each file.
                    if result?.timestamps?.needsApplication ?? true {
                        await applyTimestamps(&manifest, fileIndex: index, location: location)
                        try await persist(manifest, locations: locations)
                    }
                    // Resumed work still counts toward the phase so the bar stays honest.
                    await recordBytes(file.byteCount)
                    continue
                }
                let destination = location.originalsRoot.appending(path: file.relativeDestinationPath)
                if await fileSystem.exists(destination) {
                    let evidence = ConflictEvidence(
                        relativePath: file.relativeDestinationPath,
                        expectedByteCount: file.byteCount,
                        sourceChecksum: manifest.files[index].sourceChecksum,
                        currentResult: result,
                        compatibleRecord: indexes[location.destination.id]?[file.relativeDestinationPath])
                    let assessment = await classifier.assess(existingFileAt: destination, evidence: evidence,
                                                             fileSystem: fileSystem)
                    manifest.files[index].destinations[location.destination.id]?.conflict = assessment.classification
                    if assessment.classification.isSatisfied {
                        // Skipped only because the bytes on disk were hashed and
                        // matched the source. A matching name and size alone
                        // never reaches this branch.
                        manifest.files[index].destinations[location.destination.id]?.copyState = .skipped
                        manifest.files[index].destinations[location.destination.id]?.destinationChecksum =
                            assessment.existingChecksum
                        manifest.files[index].destinations[location.destination.id]?.verification = .verified
                        manifest.files[index].destinations[location.destination.id]?.error = nil
                        // The digest came from this run's own read of the bytes
                        // on disk, so verification has nothing left to confirm.
                        readBackThisRun.insert(ReadBack(fileIndex: index, destinationID: location.destination.id))
                        // A satisfied file is part of this archive, so it carries
                        // the same dates as everything copied beside it.
                        await applyTimestamps(&manifest, fileIndex: index, location: location)
                        try await persist(manifest, locations: locations)
                        await recordBytes(file.byteCount)
                        continue
                    }
                    if assessment.classification.isReplaceable {
                        try await fileSystem.removeIncompleteFile(destination)
                    } else {
                        // Never overwritten, never renamed around.
                        manifest.files[index].destinations[location.destination.id]?.copyState = .conflicted
                        manifest.files[index].destinations[location.destination.id]?.verification = .pending
                        manifest.files[index].destinations[location.destination.id]?.error = assessment.explanation
                        conflicts.append(DestinationConflict(
                            destinationID: location.destination.id,
                            destinationLabel: location.destination.label,
                            relativePath: file.relativeDestinationPath,
                            classification: assessment.classification,
                            existingByteCount: assessment.existingByteCount,
                            explanation: assessment.explanation))
                        try await persist(manifest, locations: locations)
                        await recordBytes(file.byteCount)
                        continue
                    }
                }
                manifest.files[index].destinations[location.destination.id]?.copyState = .copying
                try await persist(manifest, locations: locations)
                do {
                    try await fileSystem.copyExclusive(from: source, to: destination,
                                                       expectedSize: file.byteCount, onBytes: onBytes)
                    manifest.files[index].destinations[location.destination.id]?.copyState = .copied
                    await applyTimestamps(&manifest, fileIndex: index, location: location)
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
        return conflicts
    }

    // MARK: - Timestamps

    /// Carries the source's dates onto a destination copy CardVault stands
    /// behind. Deliberately non-throwing: the bytes are the product, and a date
    /// that would not write is a metadata shortfall, never a reason to fail a
    /// copy whose digest matched. Writing to the destination is not a breach of
    /// the never-touch-the-source rule — the source is still never written to.
    private func applyTimestamps(_ manifest: inout TransferManifest, fileIndex: Int, location: Location) async {
        let file = manifest.files[fileIndex]
        let url = location.originalsRoot.appending(path: file.relativeDestinationPath)
        let outcome: TimestampOutcome
        do {
            outcome = try await fileSystem.applyTimestamps(
                to: url, creationDate: file.creationDate, modificationDate: file.modificationDate,
                creationDatesSupported: location.creationDatesSupported,
                tolerance: location.timestampTolerance)
        } catch {
            outcome = TimestampOutcome(creationDate: .failed, modificationDate: .failed,
                                       error: String(describing: error))
        }
        manifest.files[fileIndex].destinations[location.destination.id]?.timestamps = outcome
    }

    /// One line per destination rather than one per file. A destination that
    /// stores no creation dates at all is silent by design; only a date that was
    /// expected to stick and did not is worth telling the user about.
    private func noteTimestampShortfalls(_ manifest: inout TransferManifest, locations: [Location]) {
        for location in locations {
            let failed = manifest.files.count { $0.destinations[location.destination.id]?.timestamps?.hasFailure == true }
            guard failed > 0 else { continue }
            manifest.warnings.append(
                "\(location.destination.label): \(failed) verified \(failed == 1 ? "file" : "files") kept the copy date "
                + "instead of the original date. The copies themselves are complete and verified.")
        }
    }

    /// Stops before verification with everything already written left intact and
    /// durably recorded, so the user can resolve each conflict and resume.
    private func pause(manifest: inout TransferManifest, locations: [Location],
                       conflicts: [DestinationConflict]) async throws -> TransferOutcome {
        manifest.state = .needsAttention
        for conflict in conflicts {
            manifest.warnings.append("\(conflict.destinationLabel): \(conflict.relativePath) — \(conflict.explanation)")
        }
        try await persist(manifest, locations: locations)
        let outcomes = locations.map { location -> DestinationOutcome in
            let values = manifest.files.compactMap { $0.destinations[location.destination.id] }
            return DestinationOutcome(id: location.destination.id, label: location.destination.label,
                                      verifiedFiles: values.count { $0.verification == .verified },
                                      failedFiles: values.count { $0.verification != .verified },
                                      finalURL: nil)
        }
        // Resuming needs the card again, so this is not the moment to eject it.
        return TransferOutcome(transferID: manifest.transferID, state: .needsAttention,
                               destinations: outcomes, safeToEject: false, conflicts: conflicts)
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
                // `.copied` and `.skipped` both mean bytes CardVault stands
                // behind are supposed to be at this path, and both are read
                // back here. A `.skipped` file recorded by an earlier run is
                // the one case where a verified claim would otherwise rest on
                // a read this process never performed — however long ago that
                // run was, and whatever happened to the file since.
                let copyState = manifest.files[index].destinations[location.destination.id]?.copyState
                let alreadyReadBack = readBackThisRun.contains(
                    ReadBack(fileIndex: index, destinationID: location.destination.id))
                guard copyState == .copied || (copyState == .skipped && !alreadyReadBack) else {
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
        noteTimestampShortfalls(&manifest, locations: locations)
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
                            originalsRoot: TransferLayout.originalsRoot(inStaging: location.finalRoot),
                            manifestURL: TransferLayout.manifestURL(inStaging: location.finalRoot),
                            finalRoot: location.finalRoot,
                            creationDatesSupported: location.creationDatesSupported,
                            timestampTolerance: location.timestampTolerance)
        }
        try await persist(manifest, locations: finalLocations)
        return TransferOutcome(transferID: plan.id,
                               state: successes == locations.count ? .verified : (successes > 0 ? .partiallySuccessful : .failed),
                               destinations: outcomes, safeToEject: true)
    }
}
