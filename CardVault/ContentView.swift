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
        .task { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Choose Source", systemImage: "sdcard") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button("Start Transfer", systemImage: "arrow.right.circle.fill") { model.beginTransfer() }
                    .disabled(model.preflight?.canProceed != true || model.isWorking)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

struct TransferView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusHeader
                HStack(alignment: .top, spacing: 18) {
                    SourceCard(model: model)
                    ConfigurationCard(model: model)
                    DestinationsCard(model: model)
                }
                if let result = model.scanResult { ScanSummary(result: result, mode: model.mode) }
                if let preflight = model.preflight { PreflightSummary(result: preflight) }
                if let progress = model.progress { PhaseProgress(progress: progress) }
                if let outcome = model.outcome { OutcomeView(outcome: outcome) }
            }.padding(24)
        }
        .navigationTitle("CardVault")
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: model.outcome?.safeToEject == true ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .font(.title).foregroundStyle(model.outcome?.safeToEject == true ? Color.green : Color.accentColor)
            VStack(alignment: .leading) {
                Text(model.message).font(.title2.weight(.semibold))
                Text(model.outcome?.safeToEject == true ? "Safe to eject does not mean safe to erase." : "CardVault reads the source and never changes it.")
                    .foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine)
            Spacer()
            if model.outcome?.safeToEject == true {
                Button("Eject Card", systemImage: "eject.fill") { model.ejectSource() }
            }
        }
    }
}

private struct SourceCard: View {
    @Bindable var model: AppModel
    var body: some View {
        GroupBox("Source") {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.sourceVolume?.displayName ?? "No source selected", systemImage: "sdcard")
                if let source = model.sourceVolume { Text(source.fileSystem).font(.caption).foregroundStyle(.secondary) }
                Button("Choose Source…") { model.chooseSource() }
                if !model.detectedVolumes.isEmpty {
                    Menu("Detected Volumes") {
                        ForEach(model.detectedVolumes) { volume in
                            Button(volume.identity.displayName) { model.selectDetectedVolume(volume) }
                        }
                    }
                }
                if model.isWorking && model.scanResult == nil { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
}

private struct ConfigurationCard: View {
    @Bindable var model: AppModel
    var body: some View {
        GroupBox("Transfer") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Transfer name", text: $model.transferName).accessibilityLabel("Transfer name")
                Picker("Mode", selection: $model.mode) {
                    ForEach(TransferMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.onChange(of: model.mode) { _, _ in model.scan() }
                Text(model.mode == .preserveCard ? "Recommended. Preserves the complete card structure." : "Relative folders are preserved. Exclusions are listed below.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
}

private struct DestinationsCard: View {
    @Bindable var model: AppModel
    var body: some View {
        GroupBox("Destinations") {
            VStack(alignment: .leading, spacing: 10) {
                Label(model.destinationURL?.lastPathComponent ?? "Choose primary", systemImage: "externaldrive")
                Button("Choose Primary…") { model.choosePrimary() }
                Divider()
                Label(model.backupURL?.lastPathComponent ?? "No backup selected", systemImage: "externaldrive.badge.plus")
                HStack {
                    Button("Choose Backup…") { model.chooseBackup() }
                    if model.backupURL != nil { Button("Remove") { model.removeBackup() } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }
}

private struct ScanSummary: View {
    let result: ScanResult; let mode: TransferMode
    var body: some View {
        GroupBox("Scan Summary") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                GridRow { Text("Files"); Text(result.files.count, format: .number) }
                GridRow { Text("Size"); Text(result.totalBytes, format: .byteCount(style: .file)) }
                GridRow { Text("RAW/JPEG pairs"); Text(result.rawJPEGPairCount, format: .number) }
                GridRow { Text("Excluded"); Text(result.excludedFiles.count, format: .number) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PreflightSummary: View {
    let result: PreflightResult
    var body: some View {
        GroupBox("Preflight") {
            VStack(alignment: .leading, spacing: 8) {
                if result.issues.isEmpty { Label("Ready to transfer", systemImage: "checkmark.circle") }
                ForEach(result.issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .blocking ? "exclamationmark.octagon" : "exclamationmark.triangle")
                        .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                }
                ForEach(result.destinations) { destination in
                    Text("\(destination.label): \(destination.fileSystem) · \(destination.requiredBytes, format: .byteCount(style: .file)) required")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PhaseProgress: View {
    let progress: TransferProgress
    var body: some View {
        GroupBox(progress.phase == .copying ? "Copying" : progress.phase == .verifying ? "Verification" : "Finalizing") {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(progress.completedBytes), total: Double(max(progress.totalBytes, 1)))
                HStack {
                    Text("\(progress.completedFiles) of \(progress.totalFiles) files")
                    Spacer()
                    Text(progress.currentRelativePath ?? "")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.accessibilityValue("\(progress.completedFiles) of \(progress.totalFiles) files")
    }
}

private struct OutcomeView: View {
    let outcome: TransferOutcome
    var body: some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(outcome.destinations) { destination in
                    Label(destination.isVerified ? "\(destination.label) verified" : "\(destination.label) incomplete",
                          systemImage: destination.isVerified ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                }
                if outcome.safeToEject { Label("Safe to eject", systemImage: "eject.fill").font(.headline) }
                HStack {
                    ForEach(outcome.destinations) { destination in
                        if let url = destination.finalURL {
                            Button("Show \(destination.label) in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Open in SDelight") {
                                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.dennisfriedrichsen.SDelight")
                                    ?? (FileManager.default.fileExists(atPath: "/Applications/SDelight.app") ? URL(filePath: "/Applications/SDelight.app") : nil)
                                else { return }
                                NSWorkspace.shared.open([url], withApplicationAt: app,
                                                        configuration: NSWorkspace.OpenConfiguration())
                            }
                        }
                    }
                }
                Text("CardVault never declares a card safe to erase.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
