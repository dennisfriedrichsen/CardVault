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
