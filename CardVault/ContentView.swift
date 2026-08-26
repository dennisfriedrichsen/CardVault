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
                if model.outcome == nil { startTransferButton }
                if let copy = model.copyProgress { PhaseProgress(progress: copy) }
                if let verification = model.verificationProgress { PhaseProgress(progress: verification) }
                if model.isFinalizing && model.outcome == nil {
                    Label("Finalizing verified transfer…", systemImage: "hourglass").font(.callout)
                }
                if let outcome = model.outcome, outcome.requiresConflictResolution {
                    ConflictsView(conflicts: outcome.conflicts)
                }
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

    private var startTransferButton: some View {
        Button {
            model.beginTransfer()
        } label: {
            Label("Start Transfer", systemImage: "arrow.right.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.preflight?.canProceed != true || model.isWorking)
        .help("Start Transfer (Command-Return)")
        .accessibilityHint("Copies and verifies the selected files at each destination.")
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
                    Text(destinationDescription(destination))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func destinationDescription(_ destination: DestinationPreflight) -> String {
        let required = destination.requiredBytes.formatted(.byteCount(style: .file))
        guard let available = destination.availableBytes else {
            return "\(destination.label): \(destination.fileSystem) · capacity unavailable · \(required) required"
        }
        return "\(destination.label): \(destination.fileSystem) · \(available.formatted(.byteCount(style: .file))) available · \(required) required"
    }
}

private struct PhaseProgress: View {
    let progress: TransferProgress

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fractionCompleted)
                HStack {
                    Text("\(progress.completedFiles) of \(progress.totalFiles) files")
                    Spacer()
                    Text(progress.currentRelativePath ?? "")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }.font(.caption)
                if let estimates {
                    Text(estimates).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Estimated performance: \(estimates)")
                }
                if progress.phase == .copying && progress.isPhaseComplete {
                    // Never present a finished copy as a finished transfer.
                    Label("Copy complete — verification still in progress",
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityValue("\(progress.completedFiles) of \(progress.totalFiles) files")
    }

    private var title: String {
        switch progress.phase {
        case .copying: "Copying"
        case .verifying: "Verification"
        case .finalizing: "Finalizing"
        }
    }

    /// Rate and remaining time are estimates and are labelled as such.
    private var estimates: String? {
        let parts = [rateText, remainingText].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "Estimated · " + parts.joined(separator: " · ")
    }

    private var rateText: String? {
        guard let rate = progress.bytesPerSecond, rate > 0, rate.isFinite else { return nil }
        return "\(Int64(rate).formatted(.byteCount(style: .file)))/s"
    }

    private var remainingText: String? {
        guard let seconds = progress.estimatedSecondsRemaining, seconds.isFinite, seconds >= 1 else { return nil }
        let clamped = min(seconds, 60 * 60 * 99)
        let formatted = Duration.seconds(Int(clamped.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        return "\(formatted) remaining"
    }
}

/// The conflict presentation flow: CardVault has stopped and is asking. Nothing
/// here offers to overwrite or to write under a different name, because neither
/// is a decision the app is entitled to make on the user's behalf.
private struct ConflictsView: View {
    let conflicts: [DestinationConflict]

    private var grouped: [(label: String, items: [DestinationConflict])] {
        Dictionary(grouping: conflicts, by: \.destinationLabel)
            .map { (label: $0.key, items: $0.value.sorted { $0.relativePath < $1.relativePath }) }
            .sorted { $0.label < $1.label }
    }

    var body: some View {
        GroupBox("Paused — \(conflicts.count) file\(conflicts.count == 1 ? "" : "s") need a decision") {
            VStack(alignment: .leading, spacing: 12) {
                Label("Nothing was overwritten and nothing was renamed. The source was not changed.",
                      systemImage: "hand.raised.fill")
                    .font(.callout.weight(.medium))
                ForEach(grouped, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.label).font(.headline)
                        ForEach(group.items) { conflict in
                            VStack(alignment: .leading, spacing: 2) {
                                // Symbol and wording carry the status; colour alone never does.
                                Label(conflict.relativePath, systemImage: symbol(for: conflict.classification))
                                    .font(.body.monospaced())
                                Text(conflict.classification.title).font(.caption.weight(.semibold))
                                Text(conflict.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(conflict.relativePath), \(conflict.classification.title)")
                            .accessibilityValue(conflict.explanation)
                        }
                    }
                }
                Text("Resolve each file on the destination, then start the transfer again to continue where it stopped.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(for classification: ConflictClassification) -> String {
        switch classification {
        case .differentContent: "doc.on.doc.fill"
        case .unrelatedFile: "questionmark.folder.fill"
        default: "exclamationmark.triangle.fill"
        }
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
                        }
                    }
                }
                Text("CardVault never declares a card safe to erase.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
