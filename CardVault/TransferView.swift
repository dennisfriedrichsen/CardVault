import AppKit
import CardVaultCore
import SwiftUI

/// The transfer screen is a fixed set of panels. Everything that can ever appear
/// has its own place from the first frame, and a change of state changes what a
/// place says, never its size or position: a user watching a progress bar or a
/// destination's result must not have it slide away because something else
/// appeared above it, and the window must never grow on its own.
struct TransferView: View {
    @Bindable var model: AppModel

    var body: some View {
        // The detail column extends under the toolbar. A plain flexible frame
        // lays out over that whole height while the content starts below the
        // toolbar, pushing the footer out of the window. A non-scrolling scroll
        // view's container-relative frame is exactly the visible region.
        ScrollView {
            content.containerRelativeFrame(.vertical, alignment: .top)
        }
        .scrollDisabled(true)
        .navigationTitle("CardVault")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader
            StepStrip(model: model)
            HStack(alignment: .top, spacing: 12) {
                SetupPanel(model: model)
                CardPanel(result: model.scanResult)
            }
            .fixedSize(horizontal: false, vertical: true)
            DestinationsPanel(model: model)
            ProgressPanel(model: model)
            IssuesPanel(model: model)
            footer
        }
        .padding(20)
    }

    /// Symbol, words and colour all carry the status independently, and the
    /// header is a single VoiceOver element that reads as one sentence. Title and
    /// detail reserve their lines so a longer message never pushes the panels.
    private var statusHeader: some View {
        let presentation = model.statusPresentation
        return HStack(spacing: 12) {
            Image(systemName: presentation.symbolName)
                .font(.title)
                .foregroundStyle(presentation.tone.color)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.message).font(.title2.weight(.semibold))
                    .lineLimit(1).truncationMode(.tail)
                Text(presentation.detail).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(model.message). \(presentation.detail)")
            primaryActionButton
        }
        .accessibilitySortPriority(100)
        .announcesStatus(presentation)
    }

    private enum PrimaryAction { case start, stop, eject }

    /// One slot, always the same size and place, offering the one thing the
    /// transfer can be told to do now — the toolbar's action slot already works
    /// this way.
    private var primaryAction: PrimaryAction {
        if model.showsStopControl { return .stop }
        if model.canEjectSource { return .eject }
        return .start
    }

    @ViewBuilder private var primaryActionButton: some View {
        switch primaryAction {
        case .start:
            Button { model.beginTransfer() } label: {
                actionLabel("Start Transfer", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            .help(startUnavailableReason ?? "Start Transfer (Command-Return)")
            .accessibilityHint(startUnavailableReason ?? "Copies and verifies the selected files at each destination.")
        case .stop:
            // Deliberately not destructive-red: stopping destroys nothing. It
            // keeps every verified file, discards only the partial write in
            // flight, and never touches the card.
            Button { model.cancelTransfer() } label: {
                actionLabel(model.isCancelling ? "Stopping…" : "Stop Transfer", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canStopTransfer)
            .help(model.stopUnavailableReason ?? "Stop the transfer (Command-Period).")
            .accessibilityHint(model.stopUnavailableReason
                ?? "Stops the transfer. Files already verified are kept, the partly written file is discarded, and the source is not changed.")
        case .eject:
            Button { model.ejectSource() } label: {
                actionLabel("Eject Card", systemImage: "eject.fill")
            }
            .buttonStyle(.bordered)
            .help("Eject the source card (Command-E). Ejecting never erases anything.")
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(width: 150)
            .padding(.vertical, 4)
    }

    /// A greyed-out control explains nothing on its own, and the tooltip a
    /// disabled control cannot show is unreachable by keyboard, so the reason is
    /// written out — in a line that is always there, so its arrival moves nothing.
    private var footer: some View {
        HStack(spacing: 12) {
            if let reason = footerReason {
                Label(reason, systemImage: model.inputLockReason != nil ? "lock" : "info.circle")
                    .lineLimit(1).truncationMode(.tail)
                    .help(reason)
            }
            Spacer(minLength: 0)
            Text("CardVault never declares a card safe to erase.")
                .lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(height: 16)
    }

    private var footerReason: String? {
        if let reason = model.inputLockReason { return reason }
        switch primaryAction {
        case .start: return startUnavailableReason
        case .stop: return model.canStopTransfer ? nil : model.stopUnavailableReason
        case .eject: return nil
        }
    }

    private var canStart: Bool { model.preflight?.canProceed == true && !model.isWorking }

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

// MARK: - Panel chrome

/// A titled panel whose title row can carry a trailing note — the lock, an
/// estimate — without that note taking a line of its own.
private struct Panel<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(title)
                Spacer()
                trailing.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension Panel where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// Stated beside a panel's title while its selections cannot change; the full
/// reason is in the footer.
private struct LockNote: View {
    let reason: String?
    var body: some View {
        if let reason {
            Label("Locked", systemImage: "lock").help(reason)
                .accessibilityLabel("Locked. \(reason)")
        }
    }
}

// MARK: - Steps

/// Where the transfer is, as four places that are always on screen. A step's
/// state is told by symbol and word; colour only repeats it.
private enum StepState: Equatable {
    case waiting, active(String), done(String), stopped, attention(String)

    var symbol: String {
        switch self {
        case .waiting: "circle.dashed"
        case .active: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .stopped: "stop.circle"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    var word: String {
        switch self {
        case .waiting: "Waiting"
        case .active(let detail), .done(let detail), .attention(let detail): detail
        case .stopped: "Stopped"
        }
    }

    var color: Color {
        switch self {
        case .waiting, .stopped: .secondary
        case .active: StatusTone.inProgress.color
        case .done: StatusTone.success.color
        case .attention: StatusTone.attention.color
        }
    }
}

private struct StepStrip: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            tile("Scan", scan)
            tile("Copy", copy)
            tile("Verify", verify)
            tile("Finalize", finalize)
        }
    }

    private func tile(_ title: String, _ state: StepState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.title3)
                .foregroundStyle(state.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline)
                Text(state.word).font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(state.word)")
    }

    private var isStopped: Bool { model.status == .cancelled }

    private var scan: StepState {
        if let result = model.scanResult {
            return result.files.isEmpty
                ? .attention("No files")
                : .done("\(result.files.count.formatted(.number)) files")
        }
        if model.isWorking && model.sourceVolume != nil { return .active("Scanning…") }
        return .waiting
    }

    private var copy: StepState {
        guard let progress = model.copyProgress else { return .waiting }
        if progress.isPhaseComplete { return .done("Done") }
        if isStopped { return .stopped }
        if model.outcome != nil || model.status == .interrupted { return .attention("Incomplete") }
        return .active("\(progress.completedFiles) of \(progress.totalFiles)")
    }

    private var verify: StepState {
        guard let progress = model.verificationProgress else { return .waiting }
        if let outcome = model.outcome {
            return outcome.destinations.allSatisfy(\.isVerified) ? .done("Done") : .attention("Incomplete")
        }
        if isStopped { return .stopped }
        if progress.isPhaseComplete { return .done("Done") }
        return .active("\(progress.completedFiles) of \(progress.totalFiles)")
    }

    private var finalize: StepState {
        if let outcome = model.outcome, model.verificationProgress != nil {
            return outcome.destinations.allSatisfy(\.isVerified) ? .done("Done") : .attention("Partly")
        }
        if model.isFinalizing { return .active("In progress") }
        return .waiting
    }
}

// MARK: - Setup

private struct SetupPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Panel(title: "Source and transfer") {
            LockNote(reason: model.inputLockReason)
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Source").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        // Ahead of the spacer, which otherwise splits the free
                        // width with the name and truncates it with room to spare.
                        Label(sourceText, systemImage: "sdcard")
                            .lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                            .accessibilityLabel(model.sourceVolume.map { "Source: \($0.displayName), \($0.fileSystem)" }
                                                ?? "Source: none selected")
                        Spacer(minLength: 4)
                        Button("Choose…") { model.chooseSource() }
                            .accessibilityLabel("Choose source")
                        Menu("Detected") {
                            ForEach(model.detectedVolumes) { volume in
                                Button(volume.identity.displayName) { model.selectDetectedVolume(volume) }
                            }
                        }
                        .fixedSize()
                        .disabled(model.detectedVolumes.isEmpty)
                        .help(model.detectedVolumes.isEmpty
                              ? "No removable volumes are mounted."
                              : "Removable volumes CardVault can see.")
                        .accessibilityHint("Removable volumes CardVault can see. Choosing one asks macOS for permission to read it.")
                    }
                }
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Transfer name", text: $model.transferName)
                        .accessibilityLabel("Transfer name")
                }
                GridRow(alignment: .top) {
                    Text("Mode").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Mode", selection: $model.mode) {
                            ForEach(TransferMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: model.mode) { _, _ in model.scan() }
                        Text(model.mode == .preserveCard
                             ? "Recommended. Preserves the complete card structure."
                             : "Relative folders are preserved. Exclusions are counted in the card summary.")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                    }
                }
            }
            .disabled(model.inputLockReason != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceText: String {
        guard let source = model.sourceVolume else { return "No source selected" }
        return "\(source.displayName) · \(source.fileSystem)"
    }
}

/// The card's contents in a fixed number of rows. What is on the card decides
/// what is listed — a video card names videos, a JPEG-only card never mentions
/// RAW — so absent categories leave their slot empty rather than claiming zero.
private struct CardPanel: View {
    let result: ScanResult?

    private static let slotCount = MediaCategory.allCases.count + 1

    var body: some View {
        Panel(title: "Card") {
            VStack(alignment: .leading, spacing: 6) {
                row("Files", result.map {
                    "\($0.files.count.formatted(.number)) · \($0.totalBytes.formatted(.byteCount(style: .file)))"
                })
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(0..<(Self.slotCount + 1) / 2, id: \.self) { line in
                        GridRow {
                            slot(at: line * 2)
                            slot(at: line * 2 + 1)
                        }
                    }
                }
                Divider()
                row("Excluded", result.map { $0.excludedFiles.count.formatted(.number) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var slots: [(title: String, value: String, spoken: String)] {
        guard let result else { return [] }
        var slots = result.composition.groups.map { group in
            let bytes = group.byteCount.formatted(.byteCount(style: .file))
            return (title: group.category.title,
                    value: "\(group.fileCount.formatted(.number)) · \(bytes)",
                    spoken: "\(group.fileCount) \(group.category.title), \(bytes)")
        }
        if result.rawJPEGPairCount > 0 {
            let count = result.rawJPEGPairCount.formatted(.number)
            slots.append((title: "RAW + JPEG pairs", value: count, spoken: "\(count) RAW plus JPEG pairs"))
        }
        return slots
    }

    @ViewBuilder private func slot(at index: Int) -> some View {
        let slots = self.slots
        if index < slots.count {
            HStack {
                Text(slots[index].title).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(slots[index].value).monospacedDigit()
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(slots[index].spoken)
        } else {
            Text(" ").accessibilityHidden(true)
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—").monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Destinations

/// One row per destination, present before a destination is even chosen. A
/// row's status reads its own result: one verified destination never speaks
/// for another that is not.
private struct DestinationsPanel: View {
    @Bindable var model: AppModel

    private enum Role { case primary, backup }

    var body: some View {
        Panel(title: "Destinations") {
            LockNote(reason: model.inputLockReason)
        } content: {
            VStack(spacing: 6) {
                row(.primary)
                Divider()
                row(.backup)
            }
        }
    }

    private func row(_ role: Role) -> some View {
        let url = role == .primary ? model.destinationURL : model.backupURL
        let roleName = role == .primary ? "Primary" : "Backup"
        let status = status(for: role, url: url)
        let finalURL = outcome(for: role)?.finalURL
        return HStack(spacing: 10) {
            Image(systemName: role == .primary ? "externaldrive" : "externaldrive.badge.plus")
                .frame(width: 20).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(roleName).frame(width: 56, alignment: .leading)
            // Truncated in the middle so both the volume and the final folder
            // stay readable; the whole path is in the tooltip and spoken label.
            Text(url.map { model.pathLabel(for: $0) } ?? (role == .primary ? "Not chosen" : "No backup"))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .help(url?.path ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(roleName) destination: \(url.map { model.pathLabel(for: $0) } ?? "none chosen")")
            Label(status.text, systemImage: status.symbol)
                .foregroundStyle(status.color)
                .monospacedDigit()
                .lineLimit(1).truncationMode(.tail)
                .help(status.text)
                .frame(width: 270, alignment: .leading)
            HStack(spacing: 6) {
                Button("Choose…") { role == .primary ? model.choosePrimary() : model.chooseBackup() }
                    .accessibilityLabel("Choose \(roleName.lowercased()) destination")
                    .disabled(model.inputLockReason != nil)
                if role == .backup {
                    Button("Remove") { model.removeBackup() }
                        .disabled(model.backupURL == nil || model.inputLockReason != nil)
                        .accessibilityLabel("Remove the backup destination")
                        .help(model.backupURL == nil
                              ? "No backup destination is chosen."
                              : "Stops writing a second copy. Nothing already written is removed.")
                } else {
                    // Holds the backup row's Remove width so both rows' buttons line up.
                    Button("Remove") {}.hidden().accessibilityHidden(true)
                }
                Button("Show in Finder") {
                    if let finalURL { NSWorkspace.shared.activateFileViewerSelecting([finalURL]) }
                }
                .disabled(finalURL == nil)
                .help(finalURL == nil ? "Available once this destination's copy is verified and finalized." : "Show the verified folder in Finder.")
                .accessibilityLabel("Show \(roleName.lowercased()) in Finder")
            }
            .controlSize(.small)
            // Button titles never truncate; the path column gives way instead.
            .fixedSize()
        }
        .frame(height: 24)
    }

    private func outcome(for role: Role) -> DestinationOutcome? {
        let label = role == .primary ? "Primary" : "Backup"
        return model.outcome?.destinations.first { $0.label == label }
    }

    private func status(for role: Role, url: URL?) -> (text: String, symbol: String, color: Color) {
        // Counts, never a fraction: a paused transfer has files that are
        // neither verified nor failed, so "7 of 7" would be a lie the moment one
        // is waiting on a decision.
        if let destination = outcome(for: role) {
            let verified = destination.verifiedFiles
            if destination.isVerified {
                return ("Verified — \(verified) file\(verified == 1 ? "" : "s")", "checkmark.seal.fill", StatusTone.success.color)
            }
            return ("Incomplete — \(verified) verified, \(destination.failedFiles) not",
                    "exclamationmark.triangle.fill", StatusTone.attention.color)
        }
        guard url != nil else {
            return (role == .primary ? "Choose a folder to copy to" : "Optional second copy", "circle.dashed", .secondary)
        }
        if model.outcome != nil { return ("No result", "minus.circle", .secondary) }
        if model.status == .cancelled { return ("Stopped", "stop.circle", .secondary) }
        if model.showsStopControl {
            if model.isFinalizing { return ("Finalizing…", "hourglass", StatusTone.inProgress.color) }
            if model.verificationProgress != nil { return ("Verifying…", "checkmark.shield", StatusTone.inProgress.color) }
            return ("Copying…", "doc.on.doc", StatusTone.inProgress.color)
        }
        let label = role == .primary ? "Primary" : "Backup"
        if let preflight = model.preflight?.destinations.first(where: { $0.label == label }) {
            let required = preflight.requiredBytes.formatted(.byteCount(style: .file))
            let available = preflight.availableBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "unknown"
            return ("\(preflight.fileSystem) · \(available) free · \(required) needed", "internaldrive", .secondary)
        }
        return ("Waiting for scan", "circle.dashed", .secondary)
    }
}

// MARK: - Progress

/// Both phases are always on screen, from an empty bar before the transfer to
/// a full one after it, so neither bar appears, disappears or pushes the other.
private struct ProgressPanel: View {
    let model: AppModel
    /// A bar that slides on every throttled snapshot is motion. The numbers are
    /// the information; the sliding is not, so it goes first.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Panel(title: "Progress") {
            Text(estimates ?? "").monospacedDigit()
                .accessibilityLabel(estimates.map { "Estimated performance: \($0)" } ?? "")
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                bar("Copy", model.copyProgress)
                bar("Verify", model.verificationProgress)
                Text(note ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var isStopped: Bool { model.status == .cancelled }

    private func bar(_ title: String, _ progress: TransferProgress?) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 56, alignment: .leading)
            // Drawn rather than a ProgressView: at zero the system bar still
            // paints a stub that reads as work begun.
            ProgressTrack(fraction: progress?.fractionCompleted ?? 0)
                .animation(reduceMotion ? nil : .default, value: progress?.fractionCompleted)
            Text(progress.map { "\($0.completedFiles) of \($0.totalFiles) files" } ?? "—")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) progress")
        .accessibilityValue(progress.map(Self.spokenValue) ?? "Not started")
    }

    /// Percentage and file counts together: a percentage alone does not say how
    /// much of the card is still only on the card.
    private static func spokenValue(_ progress: TransferProgress) -> String {
        let percent = Int((progress.fractionCompleted * 100).rounded())
        return "\(percent) percent, \(progress.completedFiles) of \(progress.totalFiles) files"
    }

    private var note: String? {
        if isStopped { return "Stopped. Verified files are kept and the source was not changed." }
        if model.isFinalizing && model.outcome == nil { return "Finalizing verified transfer…" }
        if model.outcome != nil { return nil }
        if let verification = model.verificationProgress, !verification.isPhaseComplete {
            return verification.currentRelativePath.map { "Verifying \($0)" }
                ?? "Copy complete — verification still in progress"
        }
        // Never present a finished copy as a finished transfer.
        if let copy = model.copyProgress {
            if copy.isPhaseComplete { return "Copy complete — verification still in progress" }
            return copy.currentRelativePath.map { "Copying \($0)" }
        }
        return nil
    }

    /// Rate and remaining time are estimates and are labelled as such. Only the
    /// running phase has any; a stopped or finished one is a record, not a forecast.
    private var estimates: String? {
        guard !isStopped, model.outcome == nil, model.showsStopControl else { return nil }
        let running = [model.verificationProgress, model.copyProgress]
            .compactMap { $0 }.first { !$0.isPhaseComplete }
        guard let running else { return nil }
        let parts = [rateText(running), remainingText(running)].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "Estimated · " + parts.joined(separator: " · ")
    }

    private func rateText(_ progress: TransferProgress) -> String? {
        guard let rate = progress.bytesPerSecond, rate > 0, rate.isFinite else { return nil }
        return "\(Int64(rate).formatted(.byteCount(style: .file)))/s"
    }

    private func remainingText(_ progress: TransferProgress) -> String? {
        guard let seconds = progress.estimatedSecondsRemaining, seconds.isFinite, seconds >= 1 else { return nil }
        let clamped = min(seconds, 60 * 60 * 99)
        let formatted = Duration.seconds(Int(clamped.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        return "\(formatted) remaining"
    }
}

private struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}

// MARK: - Issues

/// The one panel whose content has no fixed length — preflight findings and
/// conflicts — so it takes whatever height the window has left and scrolls
/// inside itself instead of growing the window.
private struct IssuesPanel: View {
    let model: AppModel

    var body: some View {
        Panel(title: title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A small ideal height keeps this panel from sizing itself to its
            // contents, so a long conflict list scrolls instead of growing.
            .frame(minHeight: 60, idealHeight: 60, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var title: String {
        model.outcome?.requiresConflictResolution == true ? "Files awaiting your decision" : "Preflight"
    }

    @ViewBuilder private var content: some View {
        if let outcome = model.outcome, outcome.requiresConflictResolution {
            ConflictList(conflicts: outcome.conflicts)
        } else {
            if let outcome = model.outcome, outcome.safeToEject,
               outcome.destinations.contains(where: { !$0.isVerified }) {
                // Ejecting is safe; finishing what is unverified is not possible
                // without the card, and the user is owed that before they pull it.
                Label("Completing the unverified destination later needs this card again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(StatusTone.attention.color)
            }
            if let preflight = model.preflight {
                if preflight.issues.isEmpty {
                    Label("Preflight found nothing that stops this transfer.", systemImage: "checkmark.circle")
                }
                ForEach(preflight.issues) { issue in
                    // Severity is written out. A red symbol and an orange symbol
                    // are the same symbol to anyone who cannot tell the two hues
                    // apart, and severity decides whether the transfer can start.
                    let word = issue.severity == .blocking ? "Blocking" : "Warning"
                    Label {
                        Text("\(Text(word).fontWeight(.semibold)): \(issue.message)")
                    } icon: {
                        Image(systemName: issue.severity == .blocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(issue.severity == .blocking ? StatusTone.blocked.color : StatusTone.attention.color)
                    .accessibilityLabel("\(word). \(issue.message)")
                }
            } else {
                Text("Preflight runs once a source is scanned and a primary destination is chosen.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The conflict presentation flow: CardVault has stopped and is asking. Nothing
/// here offers to overwrite or to write under a different name, because neither
/// is a decision the app is entitled to make on the user's behalf.
private struct ConflictList: View {
    let conflicts: [DestinationConflict]

    private var grouped: [(label: String, items: [DestinationConflict])] {
        Dictionary(grouping: conflicts, by: \.destinationLabel)
            .map { (label: $0.key, items: $0.value.sorted { $0.relativePath < $1.relativePath }) }
            .sorted { $0.label < $1.label }
    }

    var body: some View {
        Text("Resolve each file on the destination, then start the transfer again to continue where it stopped.")
            .font(.caption).foregroundStyle(.secondary)
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
    }

    private func symbol(for classification: ConflictClassification) -> String {
        switch classification {
        case .differentContent: "doc.on.doc.fill"
        case .unrelatedFile: "questionmark.folder.fill"
        default: "exclamationmark.triangle.fill"
        }
    }
}
