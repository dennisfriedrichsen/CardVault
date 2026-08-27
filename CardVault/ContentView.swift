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
                // The result of a finished transfer comes first. It used to sit
                // under the scan and preflight cards, which put the one thing the
                // user is waiting for below the fold in a standard window.
                if let outcome = model.outcome {
                    if outcome.requiresConflictResolution { ConflictsView(conflicts: outcome.conflicts) }
                    OutcomeView(outcome: outcome)
                }
                HStack(alignment: .top, spacing: 18) {
                    SourceCard(model: model)
                    ConfigurationCard(model: model)
                    DestinationsCard(model: model)
                }
                if let result = model.scanResult { ScanSummary(result: result, mode: model.mode) }
                if let preflight = model.preflight { PreflightSummary(result: preflight) }
                // Offering to start a transfer while one is running invites the
                // click it then refuses.
                if model.outcome == nil && !model.isWorking {
                    startTransferButton
                    if let reason = startUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityHidden(true) // Already the button's hint.
                    }
                }
                if let copy = model.copyProgress {
                    PhaseProgress(progress: copy, isTransferFinished: model.outcome != nil)
                }
                if let verification = model.verificationProgress {
                    PhaseProgress(progress: verification, isTransferFinished: model.outcome != nil)
                }
                if model.isFinalizing && model.outcome == nil {
                    Label("Finalizing verified transfer…", systemImage: "hourglass").font(.callout)
                }
            }.padding(24)
        }
        .navigationTitle("CardVault")
    }

    /// Symbol, words and colour all carry the status independently, and the
    /// header is a single VoiceOver element that reads as one sentence.
    private var statusHeader: some View {
        let presentation = model.statusPresentation
        return HStack(spacing: 12) {
            Image(systemName: presentation.symbolName)
                .font(.title)
                .foregroundStyle(presentation.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.message).font(.title2.weight(.semibold))
                Text(presentation.detail).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(model.message). \(presentation.detail)")
            Spacer()
            if model.outcome?.safeToEject == true {
                Button("Eject Card", systemImage: "eject.fill") { model.ejectSource() }
                    .keyboardShortcut("e", modifiers: .command)
                    .help("Eject the source card (Command-E). Ejecting never erases anything.")
            }
        }
        .accessibilitySortPriority(100)
        .announcesStatus(presentation)
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
        .disabled(!canStart)
        .help(startUnavailableReason ?? "Start Transfer (Command-Return)")
        .accessibilityHint(startUnavailableReason ?? "Copies and verifies the selected files at each destination.")
    }

    private var canStart: Bool { model.preflight?.canProceed == true && !model.isWorking }

    /// A greyed-out button explains nothing, and this is the button the whole
    /// screen exists for, so the reason is written out under it as well.
    private var startUnavailableReason: String? {
        if model.isWorking { return "CardVault is busy. Wait for the current operation to finish." }
        if model.sourceVolume == nil { return "Choose a source before starting a transfer." }
        if model.scanResult == nil { return "The source has not been scanned yet." }
        if model.scanResult?.files.isEmpty == true { return "The source holds no transferable files." }
        if model.destinationURL == nil { return "Choose a primary destination before starting a transfer." }
        if model.transferName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the transfer a name before starting it."
        }
        if model.preflight?.canProceed != true { return "Preflight found a blocking problem. Resolve it to continue." }
        return nil
    }
}

private struct SourceCard: View {
    @Bindable var model: AppModel
    /// A spinner is pure motion carrying one bit of information. Under reduced
    /// motion that bit is stated in words instead.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GroupBox("Source") {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.sourceVolume?.displayName ?? "No source selected", systemImage: "sdcard")
                    .accessibilityLabel(model.sourceVolume.map { "Source: \($0.displayName), \($0.fileSystem)" }
                                        ?? "Source: none selected")
                if let source = model.sourceVolume {
                    Text(source.fileSystem).font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Button("Choose Source…") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: .command)
                if !model.detectedVolumes.isEmpty {
                    Menu("Detected Volumes") {
                        ForEach(model.detectedVolumes) { volume in
                            Button(volume.identity.displayName) { model.selectDetectedVolume(volume) }
                        }
                    }
                    .accessibilityHint("Removable volumes CardVault can see. Choosing one asks macOS for permission to read it.")
                }
                if model.isWorking && model.scanResult == nil {
                    if reduceMotion {
                        Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("Scanning the source")
                    }
                }
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
                    .accessibilityLabel("Primary destination: \(model.destinationURL?.lastPathComponent ?? "none chosen")")
                Button("Choose Primary…") { model.choosePrimary() }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Label(model.backupURL?.lastPathComponent ?? "No backup selected", systemImage: "externaldrive.badge.plus")
                    .accessibilityLabel("Backup destination: \(model.backupURL?.lastPathComponent ?? "none chosen")")
                HStack {
                    Button("Choose Backup…") { model.chooseBackup() }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    if model.backupURL != nil {
                        Button("Remove") { model.removeBackup() }
                            .accessibilityLabel("Remove the backup destination")
                            .help("Stops writing a second copy. Nothing already written is removed.")
                    }
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
                // What is on the card decides what is listed. A video card names
                // videos; a JPEG-only card never mentions RAW.
                ForEach(result.composition.groups) { group in
                    GridRow {
                        Text(group.category.title)
                        Text("\(group.fileCount.formatted(.number)) · \(group.byteCount.formatted(.byteCount(style: .file)))")
                            .accessibilityLabel("\(group.fileCount) \(group.category.title), \(group.byteCount.formatted(.byteCount(style: .file)))")
                    }
                }
                if result.rawJPEGPairCount > 0 {
                    GridRow { Text("RAW + JPEG pairs"); Text(result.rawJPEGPairCount, format: .number) }
                }
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
                    // Severity is written out. A red symbol and an orange symbol
                    // are the same symbol to anyone who cannot tell the two hues
                    // apart, and severity decides whether the transfer can start.
                    Label {
                        Text("\(Text(severityWord(issue.severity)).fontWeight(.semibold)): \(issue.message)")
                    } icon: {
                        Image(systemName: issue.severity == .blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(issue.severity == .blocking ? .red : .orange)
                    .accessibilityLabel("\(severityWord(issue.severity)). \(issue.message)")
                }
                ForEach(result.destinations) { destination in
                    Text(destinationDescription(destination))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func severityWord(_ severity: PreflightSeverity) -> String {
        severity == .blocking ? "Blocking" : "Warning"
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
    /// A finished transfer has its own result. Without this the copy card kept
    /// saying verification was still in progress after it had finished.
    let isTransferFinished: Bool
    /// A bar that slides on every throttled snapshot is motion. The numbers are
    /// the information; the sliding is not, so it goes first.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fractionCompleted)
                    .animation(reduceMotion ? nil : .default, value: progress.fractionCompleted)
                    .accessibilityLabel("\(title) progress")
                    .accessibilityValue(accessibilityValue)
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
                if progress.phase == .copying && progress.isPhaseComplete && !isTransferFinished {
                    // Never present a finished copy as a finished transfer.
                    Label("Copy complete — verification still in progress",
                          systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.accessibilityValue(accessibilityValue)
    }

    /// Percentage and file counts together: a percentage alone does not say how
    /// much of the card is still only on the card.
    private var accessibilityValue: String {
        let percent = Int((progress.fractionCompleted * 100).rounded())
        return "\(percent) percent, \(progress.completedFiles) of \(progress.totalFiles) files"
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
        // The status header already names the pause and the promise that came
        // with it; repeating both here only pushed the file list down.
        GroupBox("Files awaiting your decision") {
            VStack(alignment: .leading, spacing: 12) {
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
                // Per-destination, in words and with counts: one verified
                // destination never speaks for another that is not.
                ForEach(outcome.destinations) { destination in
                    Label(summary(for: destination),
                          systemImage: destination.isVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(destination.isVerified ? Color.green : Color.orange)
                        .accessibilityLabel(summary(for: destination))
                }
                if outcome.safeToEject {
                    Label("Safe to eject", systemImage: "eject.fill").font(.headline)
                    // Ejecting is safe; finishing what is unverified is not
                    // possible without the card, and the user is owed that
                    // before they pull it.
                    if outcome.destinations.contains(where: { !$0.isVerified }) {
                        Text("Completing the unverified destination later needs this card again.")
                            .font(.callout)
                    }
                }
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

    /// Counts, never a fraction: a paused transfer has files that are neither
    /// verified nor failed, so "7 of 7" would be a lie the moment one is waiting
    /// on a decision.
    private func summary(for destination: DestinationOutcome) -> String {
        let verified = destination.verifiedFiles
        if destination.isVerified {
            return "\(destination.label) verified — \(verified) file\(verified == 1 ? "" : "s")"
        }
        return "\(destination.label) incomplete — \(verified) verified, \(destination.failedFiles) not verified"
    }
}
