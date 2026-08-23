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
    public init(safetyMarginBytes: Int64 = 1_073_741_824) { self.safetyMarginBytes = safetyMarginBytes }

    public func validate(_ plan: TransferPlan) -> PreflightResult {
        var issues: [PreflightIssue] = []
        let source = URL(filePath: plan.sourceRootPath).standardizedFileURL
        if !FileManager.default.isReadableFile(atPath: source.path) {
            issues.append(.init(code: "source-unreadable", severity: .blocking, message: "The source is unavailable or unreadable."))
        }
        if plan.destinations.isEmpty {
            issues.append(.init(code: "destination-missing", severity: .blocking, message: "Choose at least one destination."))
        }
        if plan.destinations.count == 2,
           plan.destinations[0].volume.physicalStoreIdentifier != nil,
           plan.destinations[0].volume.physicalStoreIdentifier == plan.destinations[1].volume.physicalStoreIdentifier {
            issues.append(.init(code: "same-device", severity: .warning,
                                message: "Primary and backup are on the same physical device and are not independent copies."))
        }
        var destinationChecks: [DestinationPreflight] = []
        for destination in plan.destinations {
            let url = URL(filePath: destination.rootPath).standardizedFileURL
            if url.path == source.path || url.path.hasPrefix(source.path + "/") {
                issues.append(.init(code: "destination-in-source", severity: .blocking,
                                    message: "\(destination.label) is inside the source volume."))
            }
            if source.path.hasPrefix(url.path + "/") {
                issues.append(.init(code: "source-in-destination", severity: .blocking,
                                    message: "The source is inside \(destination.label)."))
            }
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = values?.volumeAvailableCapacityForImportantUsage
            let required = plan.totalBytes + safetyMarginBytes
            if let available, available < required {
                issues.append(.init(code: "insufficient-space", severity: .blocking,
                                    message: "\(destination.label) needs more free space, including the safety margin."))
            }
            if !destination.volume.isLocal {
                issues.append(.init(code: "non-local", severity: .blocking,
                                    message: "\(destination.label) is not a directly attached local destination."))
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
