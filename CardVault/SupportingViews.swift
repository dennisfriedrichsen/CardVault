import AppKit
import CardVaultCore
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var selection: TransferHistoryEntry.ID?

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No Transfer History", systemImage: "clock.arrow.circlepath",
                                       description: Text("Verified transfers will appear here. Portable manifests remain authoritative."))
            } else {
                Table(model.history, selection: $selection) {
                    TableColumn("Transfer") { Text($0.name) }
                    TableColumn("Date") { Text($0.date, format: .dateTime.year().month().day().hour().minute()) }
                    TableColumn("Files") { Text($0.totalFiles, format: .number) }
                    TableColumn("Size") { Text($0.totalBytes, format: .byteCount(style: .file)) }
                    TableColumn("State") { Text($0.finalState.rawValue) }
                }
                .contextMenu(forSelectionType: TransferHistoryEntry.ID.self) { ids in
                    if let entry = entry(in: ids) {
                        Button("Show Manifest in Finder") { model.revealManifest(for: entry) }
                    }
                } primaryAction: { ids in
                    if let entry = entry(in: ids) { model.revealManifest(for: entry) }
                }
            }
        }.navigationTitle("Transfer History")
    }

    private func entry(in ids: Set<TransferHistoryEntry.ID>) -> TransferHistoryEntry? {
        guard let id = ids.first else { return nil }
        return model.history.first { $0.id == id }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Integrity") {
                LabeledContent("Verification", value: "SHA-256, every destination")
                LabeledContent("Source policy", value: "Strictly read-only")
            }
            Section("Performance") {
                Text("File operations are intentionally bounded and sequential in V1 for predictable removable-media behavior.")
            }
        }.formStyle(.grouped).frame(width: 520, height: 260).padding()
    }
}

struct CardVaultCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About CardVault") { showAboutPanel() }
        }
        CommandGroup(after: .newItem) {
            Button("Choose Source…") { model.chooseSource() }.keyboardShortcut("o", modifiers: .command)
            Button("Start Transfer") { model.beginTransfer() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.preflight?.canProceed != true || model.isWorking)
        }
    }

    private func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            options[.applicationIcon] = icon
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }
}
