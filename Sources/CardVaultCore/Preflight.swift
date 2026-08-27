import Foundation

public enum PreflightSeverity: String, Codable, Sendable { case warning, blocking }
public struct PreflightIssue: Codable, Hashable, Sendable, Identifiable {
    public var id: String { code + message }
    public let code: String
    public let severity: PreflightSeverity
    public let message: String
}

public struct DestinationPreflight: Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let availableBytes: Int64?
    public let requiredBytes: Int64
    public let fileSystem: String
}

public struct PreflightResult: Sendable {
    public let destinations: [DestinationPreflight]
    public let issues: [PreflightIssue]
    public var canProceed: Bool { !issues.contains { $0.severity == .blocking } }
}

public struct TransferPreflightService: Sendable {
    public var safetyMarginBytes: Int64
    private let capacityProvider: @Sendable (URL) -> Int64?

    public init(safetyMarginBytes: Int64 = 1_073_741_824) {
        self.safetyMarginBytes = safetyMarginBytes
        capacityProvider = Self.availableCapacity
    }

    init(safetyMarginBytes: Int64 = 1_073_741_824,
         capacityProvider: @escaping @Sendable (URL) -> Int64?) {
        self.safetyMarginBytes = safetyMarginBytes
        self.capacityProvider = capacityProvider
    }

    public func validate(_ plan: TransferPlan) -> PreflightResult {
        var issues: [PreflightIssue] = []
        let source = URL(filePath: plan.sourceRootPath).standardizedFileURL
        if !FileManager.default.isReadableFile(atPath: source.path) {
            issues.append(.init(code: "source-unreadable", severity: .blocking, message: "The source is unavailable or unreadable."))
        }
        if plan.destinations.isEmpty {
            issues.append(.init(code: "destination-missing", severity: .blocking, message: "Choose at least one destination."))
        }
        issues += independenceIssues(destinations: plan.destinations)
        var destinationChecks: [DestinationPreflight] = []
        for (index, destination) in plan.destinations.enumerated() {
            let url = URL(filePath: destination.rootPath).standardizedFileURL
            if url.path == source.path || url.path.hasPrefix(source.path + "/") {
                issues.append(.init(code: "destination-in-source", severity: .blocking,
                                    message: "\(destination.label) is inside the source volume."))
            }
            if source.path.hasPrefix(url.path + "/") {
                issues.append(.init(code: "source-in-destination", severity: .blocking,
                                    message: "The source is inside \(destination.label)."))
            }
            let available = capacityProvider(url)
            let required = plan.totalBytes + safetyMarginBytes
            if let available, available < required {
                issues.append(.init(code: "insufficient-space", severity: .blocking,
                                    message: "\(destination.label) has insufficient free space (\(available.formatted(.byteCount(style: .file))) available; \(required.formatted(.byteCount(style: .file))) required)."))
            }
            if !destination.volume.isLocal && index == 0 {
                issues.append(.init(code: "non-local", severity: .blocking,
                                    message: "Primary must be a directly attached local destination. Network storage can be used for Backup."))
            } else if !destination.volume.isLocal {
                issues.append(.init(code: "network-backup", severity: .warning,
                                    message: "Backup is on network storage. Keep it mounted until copying and verification finish."))
            }
            if destination.volume.fileSystem.localizedCaseInsensitiveContains("exFAT") {
                let forbidden = CharacterSet(charactersIn: "<>:\"\\|?*")
                if plan.files.contains(where: { file in
                    file.relativePath.split(separator: "/").contains { component in
                        component.rangeOfCharacter(from: forbidden) != nil || component.hasSuffix(".") || component.hasSuffix(" ")
                    }
                }) {
                    issues.append(.init(code: "exfat-name", severity: .blocking,
                                        message: "A source filename is incompatible with exFAT/Windows naming rules."))
                }
            }
            if plan.files.contains(where: { $0.relativePath.utf8.count > 1_024 }) {
                issues.append(.init(code: "path-too-long", severity: .blocking,
                                    message: "A destination path exceeds CardVault's safe path-length limit."))
            }
            destinationChecks.append(.init(id: destination.id, label: destination.label,
                                           availableBytes: available, requiredBytes: required,
                                           fileSystem: destination.volume.fileSystem))
        }
        issues += collisionIssues(files: plan.files, destinations: plan.destinations)
        return PreflightResult(destinations: destinationChecks, issues: issues)
    }

    private static func availableCapacity(at url: URL) -> Int64? {
        var reported: [Int64] = []
        if let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            if let capacity = values.volumeAvailableCapacityForImportantUsage { reported.append(capacity) }
            if let capacity = values.volumeAvailableCapacity { reported.append(Int64(capacity)) }
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let capacity = attributes[.systemFreeSize] as? NSNumber {
            reported.append(capacity.int64Value)
        }

        if let positive = reported.filter({ $0 > 0 }).max() { return positive }
        return reported.contains(0) ? 0 : nil
    }

    private func independenceIssues(destinations: [DestinationPlan]) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        for first in destinations.indices {
            for second in destinations.indices where second > first {
                let one = destinations[first]
                let other = destinations[second]
                // Overlapping roots are checked before volume identity because
                // they are the stronger fact: two destinations under one path
                // are one copy, so saying only that they share a volume would
                // understate it. Both directions of nesting are checked, so the
                // order the user picked the folders in does not change the verdict.
                if let overlap = overlapIssue(one, other) ?? overlapIssue(other, one) {
                    issues.append(overlap)
                    continue
                }
                switch one.volume.relation(to: other.volume) {
                case .sameVolume:
                    issues.append(.init(code: "same-volume", severity: .warning,
                                        message: "\(one.label) and \(other.label) are on the same volume and are not independent copies."))
                case .sameDevice:
                    issues.append(.init(code: "same-device", severity: .warning,
                                        message: "\(one.label) and \(other.label) are partitions of the same physical device and are not independent copies."))
                case .distinct, .indeterminate:
                    break
                }
            }
        }
        return issues
    }

    /// A second destination that resolves to the first, or sits inside it, is not
    /// a second copy: both write the same tree, so one deletion loses both and
    /// the transfer cannot finalise two identical folders into one name. This
    /// blocks rather than warns because the run would otherwise report a backup
    /// the user does not have.
    private func overlapIssue(_ one: DestinationPlan, _ other: DestinationPlan) -> PreflightIssue? {
        let onePath = URL(filePath: one.rootPath, directoryHint: .isDirectory).standardizedFileURL.path
        let otherPath = URL(filePath: other.rootPath, directoryHint: .isDirectory).standardizedFileURL.path
        if onePath == otherPath {
            return .init(code: "destination-overlap", severity: .blocking,
                         message: "\(one.label) and \(other.label) are the same folder, so only one copy would be made. Choose a different folder for \(other.label).")
        }
        if otherPath.hasPrefix(onePath + "/") {
            return .init(code: "destination-overlap", severity: .blocking,
                         message: "\(other.label) is inside \(one.label), so the two copies would not be independent. Choose a folder outside \(one.label) for \(other.label).")
        }
        return nil
    }

    private func collisionIssues(files: [SourceFile], destinations: [DestinationPlan]) -> [PreflightIssue] {
        let folded = Dictionary(grouping: files, by: { $0.relativePath.folding(options: [.caseInsensitive], locale: nil) })
        guard folded.values.contains(where: { Set($0.map(\.relativePath)).count > 1 }) else { return [] }
        if destinations.contains(where: { !$0.volume.fileSystem.lowercased().contains("case-sensitive") }) {
            return [.init(code: "case-collision", severity: .blocking,
                          message: "Source paths collide on a case-insensitive destination filesystem.")]
        }
        return []
    }
}
