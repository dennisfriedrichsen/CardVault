import AppKit
import CardVaultCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Integrity") {
                LabeledContent("Verification", value: "SHA-256, every destination")
                LabeledContent("Source policy", value: "Strictly read-only")
            }
            Section("Performance") {
                Text("File operations are intentionally bounded and sequential in V1 for predictable removable-media behavior.")
                Text("Transfer rate and remaining time are estimates. They never affect verification.")
                    .font(.caption).foregroundStyle(.secondary)
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
