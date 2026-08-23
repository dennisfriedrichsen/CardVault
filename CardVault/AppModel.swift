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
    var progress: TransferProgress?
    var outcome: TransferOutcome?
    var history: [TransferHistoryEntry] = []
    var detectedVolumes: [MountedVolume] = []
    var isWorking = false
    var message = "Choose an SD card or source folder to begin."
    var errorMessage: String?

    private let scanner = SourceScanner()
    private let preflightService = TransferPreflightService()
    private let coordinator = TransferCoordinator()
    private let volumeDiscovery = VolumeDiscoveryService()
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
        sourceURL = url
        sourceVolume = Self.volumeIdentity(for: url, defaultName: url.lastPathComponent, removable: true)
        Task { try? await bookmarkStore.save(url: url, key: "last-source") }
        transferName = transferName.isEmpty ? Self.defaultTransferName() : transferName
        scan()
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
        message = "Copying — do not remove card yet"
        Task {
            do {
                outcome = try await coordinator.execute(plan: plan) { [weak self] update in
                    await self?.receive(update)
                }
                message = outcome?.state == .verified ? "Transfer fully verified — Safe to eject" : "Transfer needs attention — Safe to eject"
                await recordHistory(from: outcome)
            } catch is CancellationError {
                message = "Transfer interrupted — Safe to eject"
            } catch { present(error, operation: "Transfer") }
            isWorking = false
        }
    }

    func refresh() async {
        detectedVolumes = await volumeDiscovery.mountedVolumes().filter { $0.identity.isRemovable }
        history = await historyStore.all()
        if sourceURL == nil, let access = try? await bookmarkStore.resolve(key: "last-source") {
            sourceAccess = access
            sourceURL = access.url
            sourceVolume = Self.volumeIdentity(for: access.url, defaultName: access.url.lastPathComponent, removable: true)
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

    func selectDetectedVolume(_ volume: MountedVolume) {
        sourceURL = volume.url
        sourceVolume = volume.identity
        transferName = transferName.isEmpty ? Self.defaultTransferName() : transferName
        scan()
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openInSDelight(_ url: URL) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.dennisfriedrichsen.SDelight")
                ?? (FileManager.default.fileExists(atPath: "/Applications/SDelight.app") ? URL(filePath: "/Applications/SDelight.app") : nil)
        else { errorMessage = "SDelight is not installed. The verified files remain available in Finder."; return }
        NSWorkspace.shared.open([url], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func ejectSource() {
        guard outcome?.safeToEject == true, let sourceURL else { return }
        do {
            _ = try NSWorkspace.shared.unmountAndEjectDevice(at: sourceURL)
            message = "Card ejected"
        } catch { present(error, operation: "Ejecting source") }
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
        progress = update
        switch update.phase {
        case .copying: message = "Copying — do not remove card yet"
        case .verifying: message = "Verifying copied files — do not remove card yet"
        case .finalizing: message = "Finalizing verified transfer"
        }
    }

    private func makePlan() -> TransferPlan? {
        guard let sourceURL, let sourceVolume, let scanResult, let destinationURL,
              !transferName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var destinations = [DestinationPlan(label: "Primary", rootPath: destinationURL.path,
                                            volume: Self.volumeIdentity(for: destinationURL,
                                                                        defaultName: destinationURL.lastPathComponent))]
        if let backupURL {
            destinations.append(.init(label: "Backup", rootPath: backupURL.path,
                                      volume: Self.volumeIdentity(for: backupURL, defaultName: backupURL.lastPathComponent)))
        }
        return TransferPlan(name: transferName, mode: mode, sourceRootPath: sourceURL.path,
                            sourceVolume: sourceVolume, files: scanResult.files, destinations: destinations)
    }

    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
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

    static func volumeIdentity(for url: URL, defaultName: String, removable: Bool = false) -> VolumeIdentity {
        let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey,
                                                       .volumeLocalizedFormatDescriptionKey, .volumeIsLocalKey])
        return VolumeIdentity(volumeUUID: values?.volumeUUIDString.flatMap(UUID.init(uuidString:)),
                              resourceIdentifier: values?.volumeUUIDString,
                              displayName: values?.volumeName ?? defaultName,
                              fileSystem: values?.volumeLocalizedFormatDescription ?? "Unknown",
                              isRemovable: removable, isLocal: values?.volumeIsLocal ?? true,
                              physicalStoreIdentifier: values?.volumeUUIDString)
    }

    static func defaultTransferName() -> String {
        Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}
