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
    /// The mode outlives the launch it was chosen in, like the destination
    /// selections do. Written through on every change rather than at quit, so a
    /// crash or a force-quit cannot lose the choice. A posed model never writes:
    /// a reference capture must not change the user's preferences.
    var mode: TransferMode {
        get {
            access(keyPath: \.mode)
            return storedMode
        }
        set {
            withMutation(keyPath: \.mode) { storedMode = newValue }
            guard !isPosed else { return }
            modePreference.save(newValue)
        }
    }

    @ObservationIgnored private var storedMode: TransferMode = .preserveCard

    /// Persisted for the same reason the mode is: a display the user chose must
    /// still be there next launch, because the ambiguity it resolves — several
    /// folders sharing a name — is still there too.
    var showsFullPaths: Bool {
        get {
            access(keyPath: \.showsFullPaths)
            return storedShowsFullPaths
        }
        set {
            withMutation(keyPath: \.showsFullPaths) { storedShowsFullPaths = newValue }
            guard !isPosed else { return }
            pathDisplayPreference.save(newValue)
        }
    }

    @ObservationIgnored private var storedShowsFullPaths = false

    /// How this launch names a folder on screen. Views ask the model rather than
    /// reading a URL directly, so the setting cannot be honoured on one screen
    /// and missed on another.
    func pathLabel(for url: URL) -> String {
        PathDisplay.label(for: url, showsFullPath: showsFullPaths)
    }

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

    /// Why source, name, mode and destination selection are currently
    /// unavailable, or nil when they can be changed. The running coordinator
    /// already holds the plan it was started with, so an edit made while work is
    /// under way would describe a transfer other than the one writing to disk.
    var inputLockReason: String? {
        guard isWorking else { return nil }
        if status == .scanning { return "CardVault is scanning the source. Selections can change when the scan finishes." }
        return "CardVault is busy. Selections cannot change until the current operation finishes."
    }

    /// True from the moment the user asks to stop until the coordinator has
    /// finished unwinding. It gates the stop control and keeps late progress
    /// ticks from talking over the header.
    private(set) var isCancelling = false

    /// Why the running transfer cannot be stopped right now, or nil when it can.
    /// A control that is merely greyed out teaches the user nothing about a
    /// transfer they are trying to get out of.
    var stopUnavailableReason: String? {
        if !showsStopControl { return "No transfer is running." }
        if isCancelling { return "CardVault is already stopping this transfer." }
        if isFinalizing {
            return "The transfer is being finalized. Stopping now would leave the destinations half-recorded, so it runs to the end."
        }
        return nil
    }

    var canStopTransfer: Bool { stopUnavailableReason == nil }

    /// Whether a stop control belongs on screen at all. Derived from the same
    /// published state the reference captures pose, rather than from the task
    /// handle, so a captured screen shows the control the user actually gets.
    /// A scan in progress is excluded: it has nothing durable to stop.
    var showsStopControl: Bool { isWorking && scanResult != nil && outcome == nil }

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
    @ObservationIgnored private let modePreference = TransferModePreference()
    @ObservationIgnored private let pathDisplayPreference = FullPathDisplayPreference()
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
    /// The running transfer, held for one reason: so the user can stop it.
    private var transferTask: Task<Void, Never>?

    init() {
        let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        let support = supportBase
            .appending(path: "CardVault", directoryHint: .isDirectory)
        bookmarkStore = SecurityScopedBookmarkStore(storageURL: support.appending(path: "bookmarks.plist"))
        historyStore = TransferHistoryStore(url: support.appending(path: "transfer-history.json"))
        // Restored here rather than in `refresh()` so the picker never shows a
        // mode the app is not about to use, and so the scan `refresh()` starts
        // for a restored source runs in the mode the user last chose.
        storedMode = modePreference.load()
        storedShowsFullPaths = pathDisplayPreference.load()
    }

    func chooseSource() {
        guard let url = chooseFolder(prompt: "Choose Source",
                                     initialDirectory: sourceURL ?? detectedVolumes.first?.url) else { return }
        selectSource(url)
    }

    func choosePrimary() {
        guard let url = chooseFolder(prompt: "Choose Primary Destination",
                                     initialDirectory: destinationURL ?? Self.defaultDestinationDirectory) else { return }
        destinationURL = url
        Task { try? await bookmarkStore.save(url: url, key: BookmarkKey.primary) }
        updatePreflight()
    }
    func chooseBackup() {
        guard let url = chooseFolder(prompt: "Choose Backup Destination",
                                     initialDirectory: backupURL ?? destinationURL ?? Self.defaultDestinationDirectory) else { return }
        backupURL = url
        Task { try? await bookmarkStore.save(url: url, key: BookmarkKey.backup) }
        updatePreflight()
    }
    func removeBackup() {
        backupURL = nil
        backupAccess = nil
        // Removing the backup has to outlive the window: the next refresh
        // restores any empty selection from its saved bookmark, so leaving the
        // bookmark behind puts back the destination the user just removed.
        Task { try? await bookmarkStore.remove(key: BookmarkKey.backup) }
        updatePreflight()
    }

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
                // Preflight declines to speak while work is in flight, so the
                // scan has to be over before it can replace "scanning" with the
                // state the user acts on next.
                isWorking = false
                if result.files.isEmpty { setStatus(.noTransferableFiles) }
                updatePreflight()
            } catch {
                present(error, operation: "Scanning source")
                isWorking = false
            }
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
        guard let plan = makePlan(), preflight?.canProceed == true, transferTask == nil else { return }
        isWorking = true
        isCancelling = false
        outcome = nil
        copyProgress = nil
        verificationProgress = nil
        isFinalizing = false
        setStatus(.copying)
        transferTask = Task {
            // Recorded before the first byte moves: if this run is interrupted,
            // relaunch recovery can only find these roots through these keys.
            let unrecorded = await rememberRoots(for: plan)
            if !unrecorded.isEmpty {
                let roots = unrecorded.formatted(.list(type: .and))
                errorMessage = "CardVault could not record how to reach \(roots) after a relaunch. "
                    + "The transfer will run and verify normally, but if it is interrupted it cannot "
                    + "be resumed automatically. Choosing the folders again before starting records them."
            }
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
                    setStatus(Self.completionStatus(for: outcome, destinations: plan.destinations))
                    await recordHistory(from: outcome)
                }
            } catch is CancellationError {
                setStatus(isCancelling ? .cancelled : .interrupted)
                // Stopping leaves a resumable transfer on the drives, and the
                // recovery sheet is already the app's answer to one. The
                // decision is due now rather than at the next launch.
                await discoverUnfinishedTransfers()
            } catch { present(error, operation: "Transfer") }
            isCancelling = false
            transferTask = nil
            isWorking = false
        }
    }

    /// Stops the running transfer. Everything already written stays written and
    /// stays recorded in the manifest; the file being copied when the stop lands
    /// is discarded rather than left half-written; the source is not touched at
    /// all. What is left is a transfer that can be resumed, not one that has to
    /// be started over.
    func cancelTransfer() {
        guard canStopTransfer, let transferTask else { return }
        isCancelling = true
        // The card is still being read while the coordinator unwinds, so the
        // warning that matters most has to survive the stop.
        setStatus(.copying, message: "Stopping — do not remove card yet")
        transferTask.cancel()
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
        // Ejecting unmounts the card, and the notification that follows must not
        // wipe out the confirmation the user just asked for. Another card
        // arriving does supersede it: there is something to do again.
        guard status != .ejected || !detectedVolumes.isEmpty else { return }
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
        revealFirstReachable(entry.manifestPaths.map { URL(filePath: $0) })
    }

    /// Asking whether a file exists is not free when the folder is a share: a mount whose
    /// server has stopped answering blocks the caller in the kernel until it comes back, and on
    /// the main actor that is a beachball with no way out. The question is worth asking anyway —
    /// it is what keeps the button from revealing a path on a drive that is not there — so it is
    /// asked off the main actor, where waiting costs nothing but the answer.
    private func revealFirstReachable(_ candidates: [URL]) {
        Task {
            let reachable = await Task.detached(priority: .userInitiated) {
                candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            }.value
            guard let reachable else {
                errorMessage = "The transfer manifest is unavailable. Reconnect one of the transfer destinations and try again."
                return
            }
            reveal(reachable)
        }
    }

    /// A stopped transfer has no outcome to report, but the card is in exactly
    /// the state it arrived in — CardVault never writes to a source — so there
    /// is no reason to make the user pull it from the Finder instead.
    var canEjectSource: Bool {
        sourceURL != nil && (outcome?.safeToEject == true || status == .cancelled)
    }

    func ejectSource() {
        guard canEjectSource, let sourceURL else { return }
        let name = sourceVolume?.displayName ?? sourceURL.lastPathComponent
        isWorking = true
        Task {
            do {
                try await ejectionService.eject(volumeAt: sourceURL)
                await resetAfterEjection()
                setStatus(.ejected, message: "\(name) ejected — ready for the next transfer")
            } catch let error as VolumeEjectionError {
                errorMessage = [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
                setStatus(.needsAttention, message: "\(error.volumeName) is still mounted")
            } catch {
                present(error, operation: "Ejecting \(name)")
            }
            isWorking = false
        }
    }

    /// The card is out. Everything on screen described it — its scan, its
    /// preflight, its progress, its outcome — and leaving that up invites the
    /// next transfer to be aimed at a volume that is no longer mounted. The
    /// finished run is not lost: it was recorded in History before the eject was
    /// offered. The destinations stay, because those are a standing choice
    /// rather than part of the transfer that just ended.
    private func resetAfterEjection() async {
        sourceAccess = nil
        sourceURL = nil
        sourceVolume = nil
        scanResult = nil
        preflight = nil
        copyProgress = nil
        verificationProgress = nil
        isFinalizing = false
        outcome = nil
        transferName = Self.defaultTransferName()
        // Restoring the last source on the next refresh would put the card that
        // was just ejected straight back on the screen.
        try? await bookmarkStore.remove(key: BookmarkKey.lastSource)
        detectedVolumes = await volumeDiscovery.mountedVolumes().filter { $0.identity.isRemovable }
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
        // The sheet's only way out lives beside the transfers it lists, so a
        // scan that has emptied out — the last transfer resumed or abandoned —
        // would leave an empty sheet with nothing left to dismiss it.
        isPresentingRecovery = !scan.isEmpty
    }

    func resume(_ transfer: RecoverableTransfer) {
        isWorking = true
        outcome = nil
        copyProgress = nil
        verificationProgress = nil
        isFinalizing = false
        isPresentingRecovery = false
        isCancelling = false
        section = .transfer
        setStatus(.copying, message: "Resuming \(transfer.name) — do not remove card yet")
        transferTask = Task {
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
                    setStatus(Self.completionStatus(for: outcome, destinations: plan.destinations))
                    await recordHistory(from: outcome)
                    await forgetRoots(transferID: transfer.id)
                }
            } catch is CancellationError {
                setStatus(isCancelling ? .cancelled : .interrupted,
                          message: isCancelling ? "Resume stopped — Safe to eject" : "Resume interrupted — Safe to eject")
            } catch { present(error, operation: "Resuming \(transfer.name)") }
            await discoverUnfinishedTransfers()
            isCancelling = false
            transferTask = nil
            isWorking = false
        }
    }

    func inspect(_ transfer: RecoverableTransfer) {
        // Pure and read-only, so it needs no actor hop and no task.
        inspection = recoveryCoordinator.inspect(transfer)
    }

    func revealManifest(for transfer: RecoverableTransfer) {
        revealFirstReachable(transfer.destinations.compactMap(\.manifestURL))
    }

    func revealManifest(for inspection: RecoveryInspection) {
        revealFirstReachable(inspection.manifestURLs)
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

    /// Returns the roots whose keys could not be written. A failure here costs
    /// nothing now and everything later, so it is reported rather than dropped:
    /// without these keys an interrupted transfer cannot be resumed at all.
    private func rememberRoots(for plan: TransferPlan) async -> [String] {
        var unrecorded: [String] = []
        if let sourceURL {
            do {
                try await bookmarkStore.save(url: sourceAccess?.url ?? sourceURL,
                                             key: BookmarkKey.source(transferID: plan.id))
            } catch {
                unrecorded.append(sourceVolume?.displayName ?? "the source")
            }
        }
        // A URL rebuilt from a path string is not the one the open panel granted
        // access to, and only that one can be bookmarked with security scope.
        let granted = [primaryAccess?.url ?? destinationURL,
                       backupAccess?.url ?? backupURL].compactMap { $0 }
        for destination in plan.destinations {
            let url = granted.first { $0.path == destination.rootPath }
                ?? URL(filePath: destination.rootPath, directoryHint: .isDirectory)
            do {
                try await bookmarkStore.save(
                    url: url,
                    key: BookmarkKey.destination(transferID: plan.id, destinationID: destination.id))
            } catch {
                unrecorded.append(destination.label)
            }
        }
        return unrecorded
    }

    private func forgetRoots(transferID: UUID) async {
        try? await bookmarkStore.removeAll(withPrefix: "\(BookmarkKey.transferPrefix)\(transferID.uuidString)/")
    }

    private func recordHistory(from outcome: TransferOutcome?) async {
        guard let outcome else { return }
        // Keyed by destination, so a manifest path is never recorded against
        // the wrong drive.
        // A destination that did not finish still has a durable record, in its
        // staging tree. Keying only off `finalURL` would leave history unable to
        // name it, and a connected drive would be reported as not connected.
        let paths = outcome.destinations.reduce(into: [UUID: String]()) { paths, destination in
            guard let url = destination.manifestURL else { return }
            paths[destination.id] = url.path
        }
        // Read back from a destination that finished where there is one: its
        // record is the furthest along, and the choice is not left to dictionary
        // ordering.
        guard let authority = outcome.destinations.first(where: { $0.finalURL != nil })?.manifestURL
                ?? outcome.destinations.compactMap(\.manifestURL).first,
              let manifest = try? await ManifestStore().load(from: authority) else { return }
        try? await historyStore.add(.init(manifest: manifest, manifestPaths: paths))
        history = await historyStore.all()
        await refreshHistoryDetail()
    }

    private func receive(_ update: TransferProgress) {
        switch update.phase {
        case .copying: copyProgress = update
        case .verifying: verificationProgress = update
        case .finalizing: isFinalizing = true
        }
        // A stop has already said so in the header. A snapshot still in flight
        // behind it must not put the transfer back to "copying".
        guard !isCancelling else { return }
        switch update.phase {
        case .copying:
            // A copy at 100 percent is still not a success; verification decides.
            setStatus(update.isPhaseComplete ? .copyCompleteVerificationPending : .copying)
        case .verifying: setStatus(.verifying)
        case .finalizing: setStatus(.finalizing)
        }
    }

    /// A verified primary never stands in for a finished transfer: a run that
    /// left any destination unverified is named for what is still missing.
    private static func completionStatus(for outcome: TransferOutcome?,
                                         destinations: [DestinationPlan]) -> PrincipalUIState {
        guard let outcome else { return .needsAttention }
        if outcome.state == .verified {
            // Verified either way; the state differs only in saying where the copies went.
            return outcome.isOnNetworkStorageOnly(given: destinations) ? .verifiedNetworkOnly : .verified
        }
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

    /// Every picker names its own starting directory. `NSOpenPanel` otherwise
    /// reopens wherever the last panel left off, so choosing a destination
    /// started on the card the user had just picked as the source.
    static let defaultDestinationDirectory = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask).first
        ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)

    /// Fixed `yyyy-MM-dd`, independent of locale, so names sort chronologically
    /// and don't depend on the user's month/day ordering preference.
    static func defaultTransferName() -> String {
        Date.now.formatted(.iso8601.year().month().day())
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
