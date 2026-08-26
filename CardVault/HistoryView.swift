import AppKit
import CardVaultCore
import SwiftUI

/// Looks up an installed companion app. The app layer owns this because it is
/// the only part of CardVault that is allowed to know about Launch Services.
struct WorkspaceApplicationLocator: ExternalApplicationLocator {
    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }
}

struct HistoryView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No Transfer History", systemImage: "clock.arrow.circlepath",
                                       description: Text("Verified transfers will appear here. Portable manifests remain authoritative."))
            } else {
                VSplitView {
                    transferTable
                        .frame(minHeight: 140, idealHeight: 200)
                    detail
                        .frame(minHeight: 240, idealHeight: 380, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Transfer History")
        .onChange(of: model.historySelection) { _, id in model.selectHistoryEntry(id) }
    }

    private var transferTable: some View {
        Table(model.history, selection: $model.historySelection) {
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

    @ViewBuilder
    private var detail: some View {
        if let detail = model.historyDetail {
            HistoryDetailView(model: model, detail: detail)
        } else if model.historySelection != nil {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the transfer manifest from its destinations…")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Transfer Selected", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a transfer to see its destinations, verification results, and manifest."))
        }
    }

    private func entry(in ids: Set<TransferHistoryEntry.ID>) -> TransferHistoryEntry? {
        guard let id = ids.first else { return nil }
        return model.history.first { $0.id == id }
    }
}

/// A read-only audit view of one past transfer. Nothing here changes a
/// destination, a manifest, or the index; the actions only reveal, open, or
/// hand a folder to another app.
struct HistoryDetailView: View {
    @Bindable var model: AppModel
    let detail: HistoryDetail

    private var entry: TransferHistoryEntry { detail.entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let note = detail.authorityNote { authorityBanner(note) }
                if !detail.discrepancies.isEmpty { discrepancyTable }
                summary
                if !entry.warnings.isEmpty { warnings }
                destinations
                Text("The portable manifest at each destination is the authoritative record. This history is only an index, and the photographs remain usable without CardVault.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.title2.weight(.semibold))
                Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(entry.finalState.rawValue, systemImage: entry.isFullyVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(entry.isFullyVerified ? Color.green : Color.orange)
        }.accessibilityElement(children: .combine)
    }

    private func authorityBanner(_ note: String) -> some View {
        Label(note, systemImage: "doc.badge.gearshape")
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Manifest authority: \(note)")
    }

    private var discrepancyTable: some View {
        GroupBox("Index differs from the manifest") {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text("Field").font(.caption.weight(.semibold))
                    Text("Local index").font(.caption.weight(.semibold))
                    Text("Manifest (authoritative)").font(.caption.weight(.semibold))
                }
                ForEach(detail.discrepancies) { discrepancy in
                    GridRow {
                        Text(discrepancy.field)
                        Text(discrepancy.indexValue).foregroundStyle(.secondary)
                        Text(discrepancy.manifestValue).font(.body.weight(.medium))
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summary: some View {
        GroupBox("Transfer") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                GridRow { Text("Source"); Text(sourceDescription) }
                GridRow { Text("Mode"); Text(entry.mode.title) }
                GridRow { Text("Files"); Text(entry.totalFiles, format: .number) }
                GridRow { Text("Size"); Text(entry.totalBytes, format: .byteCount(style: .file)) }
                GridRow { Text("Final state"); Text(entry.finalState.rawValue) }
                if let manifest = detail.manifest, let verified = manifest.verifiedAt {
                    GridRow { Text("Verified"); Text(verified, format: .dateTime.year().month().day().hour().minute()) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceDescription: String {
        let source = entry.source
        var parts = [source.displayName, source.fileSystem]
        if source.isRemovable { parts.append("removable") }
        return parts.joined(separator: " · ")
    }

    private var warnings: some View {
        GroupBox("Warnings recorded") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destinations: some View {
        GroupBox("Destinations") {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(detail.destinations) { status in
                    DestinationRow(model: model, status: status)
                    if status.destinationID != detail.destinations.last?.destinationID { Divider() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One destination's verification result, its availability now, and the actions
/// that availability permits. Verification and availability are shown as two
/// separate facts: a drive that is not connected is not an unverified drive.
private struct DestinationRow: View {
    @Bindable var model: AppModel
    let status: HistoryDestinationStatus

    private var handoff: HandoffAvailability { model.handoffAvailability(for: status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(status.label, systemImage: verificationSymbol)
                    .font(.headline)
                    .foregroundStyle(status.isVerified ? Color.green : Color.orange)
                Text(status.recordedVolume.displayName).foregroundStyle(.secondary)
                Spacer()
                Label(status.availability.title, systemImage: availabilitySymbol)
                    .font(.callout)
                    .foregroundStyle(status.availability.isReadable ? .primary : .secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(status.label) on \(status.recordedVolume.displayName), \(status.availability.title)")

            Text(status.verificationSummary).font(.callout)
            if !status.availability.isReadable {
                Text("This result was recorded when the transfer finished. It is not in doubt because the drive is away.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Show in Finder", systemImage: "folder") { model.reveal(status) }
                    .disabled(!status.canReveal)
                    .help(status.revealUnavailableReason ?? "Reveal this destination in Finder.")
                Button("Open Manifest", systemImage: "doc.text.magnifyingglass") { model.openManifest(status) }
                    .disabled(!status.canOpenManifest)
                    .help(status.manifestUnavailableReason ?? "Open the portable JSON manifest for inspection.")
                Button("Open in \(model.handoffName)", systemImage: "arrow.up.forward.app") { model.handOff(status) }
                    .disabled(!handoff.isReady)
                    .help(handoff.explanation ?? "Open this verified destination in \(model.handoffName).")
            }
            // An action that is only greyed out explains nothing, so the reason
            // is written out as well.
            if let reason = unavailableActionReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var unavailableActionReason: String? {
        status.revealUnavailableReason ?? handoff.explanation
    }

    private var verificationSymbol: String {
        status.isVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var availabilitySymbol: String {
        switch status.availability {
        case .available: "externaldrive.fill.badge.checkmark"
        case .indeterminate: "externaldrive.fill.badge.questionmark"
        case .mismatched: "externaldrive.fill.badge.xmark"
        case .missing: "externaldrive.badge.xmark"
        }
    }
}
