import AppKit
import CardVaultCore
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No Transfer History", systemImage: "clock.arrow.circlepath",
                                       description: Text("Verified transfers will appear here. Portable manifests remain authoritative."))
            } else {
                Table(model.history) {
                    TableColumn("Transfer") { Text($0.name) }
                    TableColumn("Date") { Text($0.date, format: .dateTime.year().month().day().hour().minute()) }
                    TableColumn("Files") { Text($0.totalFiles, format: .number) }
                    TableColumn("Size") { Text($0.totalBytes, format: .byteCount(style: .file)) }
                    TableColumn("State") { Text($0.finalState.rawValue) }
                }
            }
        }.navigationTitle("Transfer History")
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
        CommandGroup(after: .newItem) {
            Button("Choose Source…") { model.chooseSource() }.keyboardShortcut("o", modifiers: .command)
            Button("Start Transfer") { model.beginTransfer() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.preflight?.canProceed != true || model.isWorking)
        }
    }
}
