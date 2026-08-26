import AppKit
import CardVaultCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Section: Hashable { case transfer, history }
    var section: Section = .transfer
    var sourceURL: URL?
    var sourceVolume: VolumeIdentity?
    var destinationURL: URL?
    var backupURL: URL?
    var transferName = ""
    var mode: TransferMode = .preserveCard
    var scanResult: ScanResult?
    var preflight: PreflightResult?
    /// Copy and verification progress are tracked separately so a completed copy
    /// can never be rendered as a completed transfer, and so verification updates
    /// do not invalidate the copy view.
    var copyProgress: TransferProgress?
    var verificationProgress: TransferProgress?
    var isFinalizing = false
    var outcome: TransferOutcome?
    var history: [TransferHistoryEntry] = []
    /// History detail is loaded for the selected entry only, because assembling
    /// it reads a manifest off a drive that may be spinning up.
    var historySelection: TransferHistoryEntry.ID?
    var historyDetail: HistoryDetail?
    var detectedVolumes: [MountedVolume] = []
    var isWorking = false
    /// True only for a model posed by `UIStateFixture` for the reference
    /// captures. A posed model never reads or writes anything on disk.
    private(set) var isPosed = false
    /// The named state the main screen is in. One source of truth for the
    /// headline, the symbol, the tone, and what VoiceOver announces, so what the
    /// screen shows and what it says cannot drift apart.
    private(set) var status: PrincipalUIState = .noSource
    private(set) var message = StatusPresentation.for(.noSource).title
    var statusPresentation: StatusPresentation {
        StatusPresentation.for(status, conflictCount: outcome?.conflicts.count ?? 0)
    }
    var errorMessage: String?

    /// Unfinished transfers found at launch. Presented before anything else,
    /// because starting a new transfer over an interrupted one is the mistake
    /// this screen exists to prevent.
    var recovery: RecoveryScan?
    var isPresentingRecovery = false
    var inspection: RecoveryInspection?
    var pendingAbandon: (transfer: RecoverableTransfer, plan: AbandonPlan)?

    private let scanner = SourceScanner()
    private let preflightService = TransferPreflightService()
    private let coordinator = TransferCoordinator()
    private let volumeResolver = VolumeIdentityResolver(provider: DiskArbitrationTopologyProvider())
    private let volumeDiscovery = VolumeDiscoveryService()
    private let ejectionService: DiskEjectionService = DiskArbitrationEjectionService()
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let historyStore: TransferHistoryStore
    private let recoveryCoordinator = RecoveryCoordinator()
    private let historyInspector = TransferHistoryInspector()
    private let handoff = ExternalAppHandoff(locator: WorkspaceApplicationLocator())
    private var sourceAccess: SecurityScopedAccess?
    private var primaryAccess: SecurityScopedAccess?
    private var backupAccess: SecurityScopedAccess?
    /// Security-scoped access has to outlive the scan that opened it, or the
    /// URLs stop resolving the moment the last reference goes away.
    private var recoveryAccesses: [SecurityScopedAccess] = []
    /// Destination roots the app can currently reach, from the same bookmarks
    /// recovery resolves. History reconciliation reads manifests under these.
    private var knownDestinationRoots: [URL] = []

    init() {
        let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        let support = supportBase
            .appending(path: "CardVault", directoryHint: .isDirectory)
        bookmarkStore = SecurityScopedBookmarkStore(storageURL: support.appending(path: "bookmarks.plist"))
        historyStore = TransferHistoryStore(url: support.appending(path: "transfer-history.json"))
    }

    func chooseSource() {
        guard let url = chooseFolder(prompt: "Choose Source") else { return }
        selectSource(url)
    }

    func choosePrimary() {
        destinationURL = chooseFolder(prompt: "Choose Primary Destination")
        if let destinationURL { Task { try? await bookmarkStore.save(url: destinationURL, key: BookmarkKey.primary) } }
        updatePreflight()
    }
    func chooseBackup() {
        backupURL = chooseFolder(prompt: "Choose Backup Destination")
        if let backupURL { Task { try? await bookmarkStore.save(url: backupURL, key: BookmarkKey.backup) } }
        updatePreflight()
    }
    func removeBackup() { backupURL = nil; updatePreflight() }

    func scan() {
        guard let sourceURL else { return }
        isWorking = true
        scanResult = nil
        preflight = nil
        setStatus(.scanning)
        let selectedMode = mode
        Task {
            do {
                let result = try await Task.detached { try SourceScanner().scan(root: sourceURL, mode: selectedMode) }.value
                scanResult = result
                if result.files.isEmpty { setStatus(.noTransferableFiles) }
                updatePreflight()
            } catch { present(error, operation: "Scanning source") }
            isWorking = false
        }
    }

    func updatePreflight() {
        guard let plan = makePlan() else { preflight = nil; return }
        let result = preflightService.validate(plan)
        preflight = result
        // Preflight describes the states before a transfer runs. It must never
        // overwrite the outcome of one that already has.
        guard outcome == nil, !isWorking, scanResult?.files.isEmpty == false else { return }
        if !result.canProceed {
            setStatus(.preflightBlocked)
        } else {
            setStatus(result.issues.isEmpty ? .ready : .preflightWarning)
        }
    }

    func beginTransfer() {
        guard let plan = makePlan(), preflight?.canProceed == true else { return }
        isWorking = true
        outcome = nil
        copyProgress = nil
        verificationProgress = nil
        isFinalizing = false
        setStatus(.copying)
        Task {
            // Recorded before the first byte moves: if this run is interrupted,
            // relaunch recovery can only find these roots through these keys.
            await rememberRoots(for: plan)
            do {
                outcome = try await coordinator.execute(plan: plan) { [weak self] update in
                    await self?.receive(update)
                }
                isFinalizing = false
                if outcome?.requiresConflictResolution == true {
                    // Paused, not finished: the card stays mounted because
                    // resuming reads from it again.
                    setStatus(.conflictPaused)
                } else {
                    setStatus(Self.completionStatus(for: outcome))
                    await recordHistory(from: outcome)
                }
            } catch is CancellationError {
                setStatus(.interrupted)
            } catch { present(error, operation: "Transfer") }
            isWorking = false
        }
    }

    func refresh() async {
        guard !isPosed else { return }
        await refreshDetectedVolumes()
        history = await historyStore.all()
        await discoverUnfinishedTransfers()
        await reconcileHistory()
        await refreshHistoryDetail()
        if sourceURL == nil, let access = try? await bookmarkStore.resolve(key: BookmarkKey.lastSource) {
            sourceAccess = access
            sourceURL = access.url
            sourceVolume = volumeResolver.identity(for: access.url, defaultName: access.url.lastPathComponent, assumeRemovable: true)
            transferName = transferName.isEmpty ? Self.defaultTransferName() : transferName
            scan()
        }
        if destinationURL == nil, let access = try? await bookmarkStore.resolve(key: BookmarkKey.primary) {
            primaryAccess = access
            destinationURL = access.url
        }
        if backupURL == nil, let access = try? await bookmarkStore.resolve(key: BookmarkKey.backup) {
            backupAccess = access
            backupURL = access.url
        }
        updatePreflight()
    }

    func refreshDetectedVolumes() async {
        guard !isPosed else { return }
        detectedVolumes = await volumeDiscovery.mountedVolumes().filter { $0.identity.isRemovable }
        // Detecting a card is not selecting one: the status says a card is there
        // and waits, because reading it needs the user's permission first.
        guard sourceURL == nil, !isWorking else { return }
        setStatus(detectedVolumes.isEmpty ? .noSource : .sourceDetected)
    }

    func selectDetectedVolume(_ volume: MountedVolume) {
        guard let url = chooseFolder(
            prompt: "Allow Access to \(volume.identity.displayName)",
            initialDirectory: volume.url,
            message: "macOS requires your permission before CardVault can read this volume.",
            confirmButtonTitle: "Allow Access"
        ) else { return }
        let selectedVolume = url.standardizedFileURL == volume.url.standardizedFileURL ? volume.identity : nil
        selectSource(url, knownVolume: selectedVolume)
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealManifest(for entry: TransferHistoryEntry) {
        guard let path = entry.manifestPaths.first(where: FileManager.default.fileExists(atPath:)) else {
            errorMessage = "The transfer manifest is unavailable. Reconnect one of the transfer destinations and try again."
            return
        }
        reveal(URL(filePath: path))
    }

    func ejectSource() {
        guard outcome?.safeToEject == true, let sourceURL else { return }
        let name = sourceVolume?.displayName ?? sourceURL.lastPathComponent
        isWorking = true
        Task {
            do {
                try await ejectionService.eject(volumeAt: sourceURL)
                setStatus(.safeToEject, message: "\(name) ejected")
            } catch let error as VolumeEjectionError {
                errorMessage = [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
                setStatus(.needsAttention, message: "\(error.volumeName) is still mounted")
            } catch {
                present(error, operation: "Ejecting \(name)")
            }
            isWorking = false
        }
    }

    // MARK: - Transfer history

    /// Loads the selected entry's detail: destination availability now, and the
    /// authoritative manifest read back from whichever destination is connected.
    func refreshHistoryDetail() async {
        guard let id = historySelection, let entry = history.first(where: { $0.id == id }) else {
            historyDetail = nil
            return
        }
        let detail = await historyInspector.detail(for: entry)
        // The selection can move while a sleeping drive spins up.
        guard historySelection == detail.entry.id else { return }
        historyDetail = detail
    }

    func selectHistoryEntry(_ id: TransferHistoryEntry.ID?) {
        historySelection = id
        if historyDetail?.entry.id != id { historyDetail = nil }
        Task { await refreshHistoryDetail() }
    }

    func reveal(_ status: HistoryDestinationStatus) {
        guard let root = status.transferRoot else {
            errorMessage = status.revealUnavailableReason
            return
        }
        reveal(root)
    }

    /// Opens the portable manifest itself. It is plain JSON on purpose: the
    /// record has to be readable without CardVault, so inspecting it is handed
    /// to whatever the user already reads JSON with.
    func openManifest(_ status: HistoryDestinationStatus) {
        guard let url = status.manifestURL else {
            errorMessage = status.manifestUnavailableReason
            return
        }
        if !NSWorkspace.shared.open(url) { reveal(url) }
    }

    var handoffName: String { handoff.target.displayName }

    func handoffAvailability(for status: HistoryDestinationStatus) -> HandoffAvailability {
        handoff.availability(for: status)
    }

    /// Hands a verified, connected destination folder to the companion app.
    /// Nothing is copied, moved, or removed, and the transfer's record is not
    /// touched — this only opens a folder somewhere else.
    func handOff(_ status: HistoryDestinationStatus) {
        let availability = handoffAvailability(for: status)
        guard let applicationURL = availability.applicationURL, let root = status.transferRoot else {
            errorMessage = availability.explanation
            return
        }
        let name = handoff.target.displayName
        NSWorkspace.shared.open([root], withApplicationAt: applicationURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.errorMessage = "\(name) could not open \(status.label): \(reason)"
            }
        }
    }

    /// The manifests on the drives are authoritative, so an index that is
    /// missing or behind is rebuilt from them rather than trusted.
    private func reconcileHistory() async {
        let rebuilt = await historyInspector.rebuildEntries(fromDestinationRoots: knownDestinationRoots)
        guard !rebuilt.isEmpty else { return }
        _ = try? await historyStore.merge(rebuilt)
        history = await historyStore.all()
    }

    // MARK: - Relaunch recovery

    /// Rebuilds each interrupted transfer's own roots from its own bookmarks.
    /// The last-used destinations are searched too, so a transfer whose
    /// per-transfer keys predate this version is still found.
    func discoverUnfinishedTransfers() async {
        var accesses: [SecurityScopedAccess] = []
        var roots: [URL] = []
        var sources: [UUID: SecurityScopedAccess] = [:]
        var destinations: [UUID: [UUID: SecurityScopedAccess]] = [:]

        for key in await bookmarkStore.keys(withPrefix: BookmarkKey.transferPrefix) {
            guard let transferID = BookmarkKey.transferID(fromKey: key),
                  let access = try? await bookmarkStore.resolve(key: key) else { continue }
            accesses.append(access)
            if key.hasSuffix("/source") {
                sources[transferID] = access
            } else if let last = key.split(separator: "/").last,
                      let destinationID = UUID(uuidString: String(last)) {
                destinations[transferID, default: [:]][destinationID] = access
                roots.append(access.url)
            }
        }
        for key in [BookmarkKey.primary, BookmarkKey.backup] {
            guard let access = try? await bookmarkStore.resolve(key: key) else { continue }
            accesses.append(access)
            roots.append(access.url)
        }
        recoveryAccesses = accesses
        knownDestinationRoots = roots
        let scan = await recoveryCoordinator.scan(destinationRoots: roots, sourceRoots: sources,
                                                  transferDestinationRoots: destinations)
        recovery = scan
        if !scan.isEmpty { isPresentingRecovery = true }
    }

    func resume(_ transfer: RecoverableTransfer) {
        isWorking = true
        outcome = nil
        copyProgress = nil
        verificationProgress = nil
        isFinalizing = false
        isPresentingRecovery = false
        section = .transfer
        setStatus(.copying, message: "Resuming \(transfer.name) — do not remove card yet")
        Task {
            do {
                let plan = try await recoveryCoordinator.resumePlan(for: transfer)
                let manifestURL = try await recoveryCoordinator.resumeManifestURL(for: transfer)
                // Resumes at a whole-file boundary from the durable manifest;
                // files already verified are confirmed, not copied again.
                outcome = try await coordinator.resume(plan: plan, manifestURL: manifestURL) { [weak self] update in
                    await self?.receive(update)
                }
                isFinalizing = false
                if outcome?.requiresConflictResolution == true {
                    setStatus(.conflictPaused)
                } else {
                    setStatus(Self.completionStatus(for: outcome))
                    await recordHistory(from: outcome)
                    await forgetRoots(transferID: transfer.id)
                }
            } catch is CancellationError {
                setStatus(.interrupted, message: "Resume interrupted — Safe to eject")
            } catch { present(error, operation: "Resuming \(transfer.name)") }
            await discoverUnfinishedTransfers()
            isWorking = false
        }
    }

    func inspect(_ transfer: RecoverableTransfer) {
        // Pure and read-only, so it needs no actor hop and no task.
        inspection = recoveryCoordinator.inspect(transfer)
    }

    func revealManifest(for transfer: RecoverableTransfer) {
        guard let url = transfer.destinations.compactMap(\.manifestURL)
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            errorMessage = "The transfer manifest is unavailable. Reconnect one of the transfer destinations and try again."
            return
        }
        reveal(url)
    }

    /// Asks before removing anything, and shows exactly what would go.
    func confirmAbandon(_ transfer: RecoverableTransfer) {
        pendingAbandon = (transfer, recoveryCoordinator.abandonPlan(for: transfer))
    }

    func abandon(_ transfer: RecoverableTransfer, removingIncompleteArtifacts: Bool) {
        pendingAbandon = nil
        Task {
            let result = await recoveryCoordinator.abandon(
                transfer, removingIncompleteArtifacts: removingIncompleteArtifacts)
            if !result.failures.isEmpty {
                errorMessage = "Some artifacts could not be removed: \(result.failures.joined(separator: ", "))"
            }
            await forgetRoots(transferID: transfer.id)
            await discoverUnfinishedTransfers()
        }
    }

    private func rememberRoots(for plan: TransferPlan) async {
        if let sourceURL {
            try? await bookmarkStore.save(url: sourceURL, key: BookmarkKey.source(transferID: plan.id))
        }
        for destination in plan.destinations {
            try? await bookmarkStore.save(
                url: URL(filePath: destination.rootPath, directoryHint: .isDirectory),
                key: BookmarkKey.destination(transferID: plan.id, destinationID: destination.id))
        }
    }

    private func forgetRoots(transferID: UUID) async {
        try? await bookmarkStore.removeAll(withPrefix: "\(BookmarkKey.transferPrefix)\(transferID.uuidString)/")
    }

    private func recordHistory(from outcome: TransferOutcome?) async {
        guard let outcome else { return }
        // Keyed by destination, so a manifest path is never recorded against
        // the wrong drive.
        let paths = outcome.destinations.reduce(into: [UUID: String]()) { paths, destination in
            guard let url = destination.finalURL else { return }
            paths[destination.id] = TransferLayout.manifestURL(inStaging: url).path
        }
        guard let first = paths.values.first,
              let manifest = try? await ManifestStore().load(from: URL(filePath: first)) else { return }
        try? await historyStore.add(.init(manifest: manifest, manifestPaths: paths))
        history = await historyStore.all()
        await refreshHistoryDetail()
    }

    private func receive(_ update: TransferProgress) {
        switch update.phase {
        case .copying:
            copyProgress = update
            // A copy at 100 percent is still not a success; verification decides.
            setStatus(update.isPhaseComplete ? .copyCompleteVerificationPending : .copying)
        case .verifying:
            verificationProgress = update
            setStatus(.verifying)
        case .finalizing:
            isFinalizing = true
            setStatus(.finalizing)
        }
    }

    /// A verified primary never stands in for a finished transfer: a run that
    /// left any destination unverified is named for what is still missing.
    private static func completionStatus(for outcome: TransferOutcome?) -> PrincipalUIState {
        guard let outcome else { return .needsAttention }
        if outcome.state == .verified { return .verified }
        let verified = outcome.destinations.filter(\.isVerified).count
        if verified == 0 { return outcome.state == .failed ? .failed : .needsAttention }
        return verified < outcome.destinations.count ? .primaryVerifiedBackupIncomplete : .needsAttention
    }

    /// `@Observable` publishes every assignment, so equal writes are dropped here
    /// rather than re-invalidating every view that reads `status` or `message`.
    private func setStatus(_ next: PrincipalUIState, message override: String? = nil) {
        let text = override ?? StatusPresentation.for(next, conflictCount: outcome?.conflicts.count ?? 0).title
        if status != next { status = next }
        if message != text { message = text }
    }

    private func makePlan() -> TransferPlan? {
        guard let sourceURL, let sourceVolume, let scanResult, let destinationURL,
              !transferName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var destinations = [DestinationPlan(label: "Primary", rootPath: destinationURL.path,
                                            volume: volumeResolver.identity(for: destinationURL,
                                                                            defaultName: destinationURL.lastPathComponent))]
        if let backupURL {
            destinations.append(.init(label: "Backup", rootPath: backupURL.path,
                                      volume: volumeResolver.identity(for: backupURL, defaultName: backupURL.lastPathComponent)))
        }
        return TransferPlan(name: transferName, mode: mode, sourceRootPath: sourceURL.path,
                            sourceVolume: sourceVolume, files: scanResult.files, destinations: destinations)
    }

    private func selectSource(_ url: URL, knownVolume: VolumeIdentity? = nil) {
        sourceAccess = nil
        sourceURL = url
        sourceVolume = knownVolume
            ?? volumeResolver.identity(for: url, defaultName: url.lastPathComponent, assumeRemovable: true)
        Task { try? await bookmarkStore.save(url: url, key: BookmarkKey.lastSource) }
        transferName = transferName.isEmpty ? Self.defaultTransferName() : transferName
        scan()
    }

    private func chooseFolder(prompt: String, initialDirectory: URL? = nil,
                              message: String? = nil, confirmButtonTitle: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.directoryURL = initialDirectory
        panel.message = message
        if let confirmButtonTitle { panel.prompt = confirmButtonTitle }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func present(_ error: Error, operation: String) {
        errorMessage = "\(operation) failed: \(error.localizedDescription). The source was not modified. You can inspect the incomplete destination and try again."
        setStatus(.needsAttention)
    }

    static func defaultTransferName() -> String {
        Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}

#if DEBUG
extension AppModel {
    /// Poses the model in one `PrincipalUIState` for the reference captures.
    ///
    /// It lives in this file because `status` and `message` are deliberately
    /// `private(set)`: a fixture is allowed to pose the app, but nothing else in
    /// the app may write a status without going through `setStatus`. A posed
    /// model does no I/O at all — `refresh()` returns immediately — so a capture
    /// can never touch a real card, drive, or history file.
    convenience init(fixture: UIStateFixture) {
        self.init()
        isPosed = true
        pose(fixture)
    }

    func pose(_ fixture: UIStateFixture) {
        transferName = fixture.transferName
        mode = fixture.mode
        sourceVolume = fixture.sourceVolume
        sourceURL = fixture.sourcePath.map { URL(filePath: $0, directoryHint: .isDirectory) }
        destinationURL = fixture.destinationName.map { URL(filePath: "/Volumes/\($0)", directoryHint: .isDirectory) }
        backupURL = fixture.backupName.map { URL(filePath: "/Volumes/\($0)", directoryHint: .isDirectory) }
        detectedVolumes = fixture.detectedVolumes
        scanResult = fixture.scan
        preflight = fixture.preflight
        copyProgress = fixture.copyProgress
        verificationProgress = fixture.verificationProgress
        isFinalizing = fixture.isFinalizing
        isWorking = fixture.isWorking
        outcome = fixture.outcome
        recovery = fixture.recovery
        isPresentingRecovery = fixture.recovery?.isEmpty == false
        section = .transfer
        errorMessage = nil
        // Set last: it reads `outcome` for the conflict count.
        setStatus(fixture.state)
    }
}
#endif
