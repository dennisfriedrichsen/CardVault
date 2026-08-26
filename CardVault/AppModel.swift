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
    var detectedVolumes: [MountedVolume] = []
    var isWorking = false
    var message = "Choose an SD card or source folder to begin."
    var errorMessage: String?

    private let scanner = SourceScanner()
    private let preflightService = TransferPreflightService()
    private let coordinator = TransferCoordinator()
    private let volumeResolver = VolumeIdentityResolver(provider: DiskArbitrationTopologyProvider())
    private let volumeDiscovery = VolumeDiscoveryService()
    private let ejectionService: DiskEjectionService = DiskArbitrationEjectionService()
    private let bookmarkStore: SecurityScopedBookmarkStore
    private let historyStore: TransferHistoryStore
    private var sourceAccess: SecurityScopedAccess?
    private var primaryAccess: SecurityScopedAccess?
    private var backupAccess: SecurityScopedAccess?

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
        if let destinationURL { Task { try? await bookmarkStore.save(url: destinationURL, key: "primary") } }
        updatePreflight()
    }
    func chooseBackup() {
        backupURL = chooseFolder(prompt: "Choose Backup Destination")
        if let backupURL { Task { try? await bookmarkStore.save(url: backupURL, key: "backup") } }
        updatePreflight()
    }
    func removeBackup() { backupURL = nil; updatePreflight() }

    func scan() {
        guard let sourceURL else { return }
        isWorking = true
        scanResult = nil
        preflight = nil
        message = "Scanning source without modifying it…"
        let selectedMode = mode
        Task {
            do {
                let result = try await Task.detached { try SourceScanner().scan(root: sourceURL, mode: selectedMode) }.value
                scanResult = result
                message = result.files.isEmpty ? "No transferable files found." : "Ready to transfer"
                updatePreflight()
            } catch { present(error, operation: "Scanning source") }
            isWorking = false
        }
    }

    func updatePreflight() {
        guard let plan = makePlan() else { preflight = nil; return }
        preflight = preflightService.validate(plan)
    }

    func beginTransfer() {
        guard let plan = makePlan(), preflight?.canProceed == true else { return }
        isWorking = true
        outcome = nil
        copyProgress = nil
        verificationProgress = nil
        isFinalizing = false
        message = "Copying — do not remove card yet"
        Task {
            do {
                outcome = try await coordinator.execute(plan: plan) { [weak self] update in
                    await self?.receive(update)
                }
                isFinalizing = false
                message = outcome?.state == .verified ? "Transfer fully verified — Safe to eject" : "Transfer needs attention — Safe to eject"
                await recordHistory(from: outcome)
            } catch is CancellationError {
                message = "Transfer interrupted — Safe to eject"
            } catch { present(error, operation: "Transfer") }
            isWorking = false
        }
    }

    func refresh() async {
        await refreshDetectedVolumes()
        history = await historyStore.all()
        if sourceURL == nil, let access = try? await bookmarkStore.resolve(key: "last-source") {
            sourceAccess = access
            sourceURL = access.url
            sourceVolume = volumeResolver.identity(for: access.url, defaultName: access.url.lastPathComponent, assumeRemovable: true)
            transferName = transferName.isEmpty ? Self.defaultTransferName() : transferName
            scan()
        }
        if destinationURL == nil, let access = try? await bookmarkStore.resolve(key: "primary") {
            primaryAccess = access
            destinationURL = access.url
        }
        if backupURL == nil, let access = try? await bookmarkStore.resolve(key: "backup") {
            backupAccess = access
            backupURL = access.url
        }
        updatePreflight()
    }

    func refreshDetectedVolumes() async {
        detectedVolumes = await volumeDiscovery.mountedVolumes().filter { $0.identity.isRemovable }
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
                message = "\(name) ejected"
            } catch let error as VolumeEjectionError {
                errorMessage = [error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
                message = "\(error.volumeName) is still mounted"
            } catch {
                present(error, operation: "Ejecting \(name)")
            }
            isWorking = false
        }
    }

    private func recordHistory(from outcome: TransferOutcome?) async {
        guard let outcome else { return }
        let paths = outcome.destinations.compactMap { $0.finalURL?.appending(path: ".cardvault/transfer-manifest.json") }
        guard let first = paths.first,
              let manifest = try? await ManifestStore().load(from: first) else { return }
        try? await historyStore.add(.init(manifest: manifest, manifestPaths: paths.map(\.path)))
        history = await historyStore.all()
    }

    private func receive(_ update: TransferProgress) {
        switch update.phase {
        case .copying:
            copyProgress = update
            // A copy at 100 percent is still not a success; verification decides.
            setMessage(update.isPhaseComplete
                       ? "Copy complete — verifying, do not remove card yet"
                       : "Copying — do not remove card yet")
        case .verifying:
            verificationProgress = update
            setMessage("Verifying copied files — do not remove card yet")
        case .finalizing:
            isFinalizing = true
            setMessage("Finalizing verified transfer")
        }
    }

    /// `@Observable` publishes every assignment, so equal writes are dropped here
    /// rather than re-invalidating every view that reads `message`.
    private func setMessage(_ text: String) {
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
        Task { try? await bookmarkStore.save(url: url, key: "last-source") }
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
        message = "Transfer needs attention"
    }

    static func defaultTransferName() -> String {
        Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}
