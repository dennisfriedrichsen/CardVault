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
        // Every shortcut the window offers also lives in a menu: a shortcut that
        // exists only on a toolbar button cannot be discovered, and Full Keyboard
        // Access users reach the menu bar first.
        CommandGroup(after: .newItem) {
            // Disabled for the same reason as the cards themselves: a plan that
            // is already running cannot take a new source or destination.
            Button("Choose Source…") { model.chooseSource() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.inputLockReason != nil)
            Button("Choose Primary Destination…") { model.choosePrimary() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.inputLockReason != nil)
            Button("Choose Backup Destination…") { model.chooseBackup() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.inputLockReason != nil)
            Divider()
            Button("Start Transfer") { model.beginTransfer() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.preflight?.canProceed != true || model.isWorking)
            Button("Eject Card") { model.ejectSource() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.outcome?.safeToEject != true)
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
