import AppKit
import CardVaultCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.section) {
                Label("New Transfer", systemImage: "sdcard").tag(AppModel.Section.transfer)
                Label("History", systemImage: "clock.arrow.circlepath").tag(AppModel.Section.history)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            switch model.section {
            case .transfer: TransferView(model: model)
            case .history: HistoryView(model: model)
            }
        }
        .alert("CardVault Needs Attention", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.isPresentingRecovery) {
            if let scan = model.recovery, !scan.isEmpty { RecoveryView(model: model, scan: scan) }
        }
        .task { await model.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await model.refreshDetectedVolumes() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await model.refreshDetectedVolumes() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Choose Source", systemImage: "sdcard") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.inputLockReason != nil)
                    .help(model.inputLockReason ?? "Choose the card or folder to copy from (Command-O).")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                // The two are exclusive on purpose: the toolbar's action slot
                // always offers the one thing the transfer can be told to do now.
                if model.showsStopControl {
                    Button("Stop Transfer", systemImage: "stop.circle.fill") { model.cancelTransfer() }
                        .disabled(!model.canStopTransfer)
                        .keyboardShortcut(".", modifiers: .command)
                        .help(model.stopUnavailableReason ?? "Stop the transfer (Command-Period). Verified files are kept and the source is not touched.")
                } else {
                    Button("Start Transfer", systemImage: "arrow.right.circle.fill") { model.beginTransfer() }
                        .disabled(model.preflight?.canProceed != true || model.isWorking)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }
}
