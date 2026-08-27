import AppKit
import CardVaultCore
import SwiftUI

/// Presented at launch when unfinished transfers are found. Every action here is
/// explicit: nothing resumes, repairs, or deletes because a sheet appeared.
struct RecoveryView: View {
    @Bindable var model: AppModel
    let scan: RecoveryScan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(scan.transfers) { transfer in
                        RecoverableTransferCard(model: model, transfer: transfer)
                    }
                    if !scan.unreadable.isEmpty {
                        UnreadableTransfersCard(model: model, transfers: scan.unreadable)
                    }
                }.padding(20)
            }
            Divider()
            HStack {
                Text("Your source card has not been changed.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Decide Later") { model.isPresentingRecovery = false }
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 560)
        .sheet(item: Binding(get: { model.inspection }, set: { model.inspection = $0 })) { inspection in
            InspectionView(model: model, inspection: inspection)
        }
        .alert("Abandon this transfer?", isPresented: Binding(
            get: { model.pendingAbandon != nil },
            set: { if !$0 { model.pendingAbandon = nil } }
        ), presenting: model.pendingAbandon) { pending in
            if !pending.plan.removesNothing {
                Button("Abandon and Remove Partial Files", role: .destructive) {
                    model.abandon(pending.transfer, removingIncompleteArtifacts: true)
                }
            }
            Button("Abandon and Keep Everything") {
                model.abandon(pending.transfer, removingIncompleteArtifacts: false)
            }
            Button("Cancel", role: .cancel) { model.pendingAbandon = nil }
        } message: { pending in
            Text(abandonMessage(for: pending.plan))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.largeTitle).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfinished Transfers").font(.title2.weight(.semibold))
                Text(summary).foregroundStyle(.secondary)
            }.accessibilityElement(children: .combine)
            Spacer()
        }.padding(20)
    }

    private var summary: String {
        let transfers = scan.transfers.count
        let unreadable = scan.unreadable.count
        var parts: [String] = []
        if transfers > 0 { parts.append("\(transfers) transfer\(transfers == 1 ? "" : "s") did not finish") }
        if unreadable > 0 { parts.append("\(unreadable) record\(unreadable == 1 ? "" : "s") could not be read") }
        return parts.joined(separator: " · ")
    }

    private func abandonMessage(for plan: AbandonPlan) -> String {
        var lines = ["The source card is never changed."]
        if plan.verifiedFilesKept > 0 {
            lines.append("\(plan.verifiedFilesKept) verified file\(plan.verifiedFilesKept == 1 ? "" : "s") will be kept.")
        }
        if plan.conflictedFilesKept > 0 {
            lines.append("\(plan.conflictedFilesKept) file\(plan.conflictedFilesKept == 1 ? "" : "s") awaiting a decision will be kept.")
        }
        if plan.removesNothing {
            lines.append("Nothing will be removed.")
        } else {
            let count = plan.removableIncompleteArtifacts.count
            lines.append("\(count) partially written file\(count == 1 ? "" : "s") can be removed. Nothing else is touched:")
            // Named, not counted. A count cannot be checked against the drive;
            // a path can, and the plan promises the user can see what goes.
            let shown = 8
            lines.append(contentsOf: plan.removableDescriptions.prefix(shown).map { "  \($0)" })
            if plan.removableDescriptions.count > shown {
                lines.append("  and \(plan.removableDescriptions.count - shown) more")
            }
        }
        if !plan.refusedPaths.isEmpty {
            lines.append("\(plan.refusedPaths.count) record\(plan.refusedPaths.count == 1 ? "" : "s") "
                + "name a path outside this transfer's folder and will be left alone.")
        }
        lines.append("The transfer record is kept so you can still inspect it.")
        return lines.joined(separator: "\n")
    }
}

private struct RecoverableTransferCard: View {
    @Bindable var model: AppModel
    let transfer: RecoverableTransfer

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(transfer.name).font(.headline)
                    Spacer()
                    Text(transfer.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Wording carries the state; colour is never the only signal.
                Label("Stopped while: \(transfer.interruptedOperation.title)", systemImage: "pause.circle.fill")
                    .font(.callout)
                Text("Last recorded state: \(transfer.lastDurableState.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)

                counts
                volumes

                if !transfer.warnings.isEmpty || !transfer.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((transfer.errors + transfer.warnings).prefix(4)), id: \.self) { note in
                            Label(note, systemImage: "exclamationmark.bubble").font(.caption)
                        }
                    }
                }

                if let reason = transfer.blockingReason {
                    Label(reason, systemImage: "externaldrive.badge.questionmark")
                        .font(.callout.weight(.medium))
                }

                HStack {
                    Button("Resume") { model.resume(transfer) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!transfer.canResume || model.isWorking)
                    Button("Inspect") { model.inspect(transfer) }
                    Button("Reveal Manifest") { model.revealManifest(for: transfer) }
                    Spacer()
                    Button("Abandon…") { model.confirmAbandon(transfer) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var counts: some View {
        HStack(spacing: 20) {
            LabeledContent("Files", value: "\(transfer.totalFiles)")
            LabeledContent("Copied", value: "\(transfer.completedFiles)")
            LabeledContent("Verified", value: "\(transfer.verifiedFiles)")
            LabeledContent("Remaining", value: "\(transfer.remainingFiles)")
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(transfer.verifiedFiles) of \(transfer.totalFiles) files verified, \(transfer.remainingFiles) remaining")
    }

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 4) {
            VolumeRow(label: "Source", name: transfer.source.recordedVolume.displayName,
                      match: transfer.source.match, wasStale: transfer.source.bookmarkWasStale)
            ForEach(transfer.destinations) { destination in
                VolumeRow(label: destination.label, name: destination.recordedVolume.displayName,
                          match: destination.match, wasStale: destination.bookmarkWasStale)
            }
        }
    }
}

private struct VolumeRow: View {
    let label: String
    let name: String
    let match: RecoveryVolumeMatch
    let wasStale: Bool

    var body: some View {
        Label {
            Text("\(label): \(name) — \(description)")
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(name), \(description)")
    }

    private var description: String {
        switch match {
        case .matched: wasStale ? "connected at a new location" : "connected"
        case .mismatched: "a different volume is mounted here"
        case .indeterminate: "connected, but its identity could not be confirmed"
        case .unavailable: "not connected"
        }
    }

    private var symbol: String {
        switch match {
        case .matched: "externaldrive.badge.checkmark"
        case .mismatched: "externaldrive.badge.xmark"
        case .indeterminate: "externaldrive.badge.questionmark"
        case .unavailable: "externaldrive.badge.minus"
        }
    }
}

private struct UnreadableTransfersCard: View {
    @Bindable var model: AppModel
    let transfers: [UnreadableTransfer]

    var body: some View {
        GroupBox("Records CardVault Could Not Read") {
            VStack(alignment: .leading, spacing: 10) {
                Text("These are reported rather than restarted. CardVault will not touch a transfer it cannot understand.")
                    .font(.callout)
                ForEach(transfers) { transfer in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(model.pathLabel(for: transfer.stagingRoot), systemImage: "doc.badge.gearshape")
                            .font(.callout.monospaced())
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(transfer.reason).font(.caption).foregroundStyle(.secondary)
                        if transfer.isUnsupportedSchema {
                            Text("Update CardVault to read this transfer.")
                                .font(.caption.weight(.medium))
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([transfer.manifestURL])
                        }.buttonStyle(.link)
                    }
                    .accessibilityElement(children: .combine)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Read-only. Nothing on this screen writes to a transfer artifact.
private struct InspectionView: View {
    @Bindable var model: AppModel
    let inspection: RecoveryInspection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(inspection.transferName).font(.title3.weight(.semibold))
                    Text("\(inspection.files.count) files · inspection does not modify anything")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(16)
            Divider()
            Table(inspection.files) {
                TableColumn("File") { Text($0.relativePath).font(.body.monospaced()) }
                TableColumn("Size") {
                    Text($0.byteCount.formatted(.byteCount(style: .file)))
                }
                TableColumn("Copy") { file in
                    Text(file.destinations.map(\.copyState.rawValue).joined(separator: ", "))
                }
                TableColumn("Verification") { file in
                    Text(file.destinations.map(\.verification.rawValue).joined(separator: ", "))
                }
                TableColumn("Note") { file in
                    Text(file.destinations.compactMap { $0.conflict?.title ?? $0.error }
                        .joined(separator: "; "))
                }
            }
            Divider()
            HStack {
                Button("Reveal Manifest") { model.revealManifest(for: inspection) }
                Spacer()
                Button("Done") { model.inspection = nil }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 720, minHeight: 420)
    }
}
