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
    private let readabilityProvider: @Sendable (URL) -> Bool
    /// Whether a destination keeps two names that differ only in case as two
    /// files. Nil when the mount will not say.
    private let caseSensitivityProvider: @Sendable (URL) -> Bool?

    public init(safetyMarginBytes: Int64 = 1_073_741_824) {
        self.safetyMarginBytes = safetyMarginBytes
        capacityProvider = Self.availableCapacity
        readabilityProvider = Self.isReadable
        caseSensitivityProvider = Self.supportsCaseSensitiveNames
    }

    /// Every probe is injectable so that `validate` can be run as a pure
    /// function of a plan. That is what lets the UI fixtures derive their
    /// preflight results from the real check rather than hand-writing issues
    /// that no code path produces.
    init(safetyMarginBytes: Int64 = 1_073_741_824,
         capacityProvider: @escaping @Sendable (URL) -> Int64?,
         readabilityProvider: @escaping @Sendable (URL) -> Bool = Self.isReadable,
         caseSensitivityProvider: @escaping @Sendable (URL) -> Bool? = Self.supportsCaseSensitiveNames) {
        self.safetyMarginBytes = safetyMarginBytes
        self.capacityProvider = capacityProvider
        self.readabilityProvider = readabilityProvider
        self.caseSensitivityProvider = caseSensitivityProvider
    }

    init(safetyMarginBytes: Int64 = 1_073_741_824,
         caseSensitivityProvider: @escaping @Sendable (URL) -> Bool?) {
        self.safetyMarginBytes = safetyMarginBytes
        capacityProvider = Self.availableCapacity
        readabilityProvider = Self.isReadable
        self.caseSensitivityProvider = caseSensitivityProvider
    }

    public func validate(_ plan: TransferPlan) -> PreflightResult {
        var issues: [PreflightIssue] = []
        let source = URL(filePath: plan.sourceRootPath).standardizedFileURL
        if !readabilityProvider(source) {
            issues.append(.init(code: "source-unreadable", severity: .blocking, message: "The source is unavailable or unreadable."))
        }
        if plan.destinations.isEmpty {
            issues.append(.init(code: "destination-missing", severity: .blocking, message: "Choose at least one destination."))
        }
        // Capacity is read once per destination and then shared: the independence check needs
        // it too, because two mounts on one server reporting identical free space is evidence
        // they draw on one pool.
        let destinationURLs = plan.destinations.map { URL(filePath: $0.rootPath).standardizedFileURL }
        let availableBytes = destinationURLs.map(capacityProvider)
        issues += independenceIssues(destinations: plan.destinations, availableBytes: availableBytes)
        issues += networkIssues(destinations: plan.destinations)
        var destinationChecks: [DestinationPreflight] = []
        for (index, destination) in plan.destinations.enumerated() {
            let url = destinationURLs[index]
            if url.path == source.path || url.path.hasPrefix(source.path + "/") {
                issues.append(.init(code: "destination-in-source", severity: .blocking,
                                    message: "\(destination.label) is inside the source volume."))
            }
            if source.path.hasPrefix(url.path + "/") {
                issues.append(.init(code: "source-in-destination", severity: .blocking,
                                    message: "The source is inside \(destination.label)."))
            }
            let available = availableBytes[index]
            let required = plan.totalBytes + safetyMarginBytes
            if let available, available < required {
                issues.append(.init(code: "insufficient-space", severity: .blocking,
                                    message: "\(destination.label) has insufficient free space (\(available.formatted(.byteCount(style: .file))) available; \(required.formatted(.byteCount(style: .file))) required)."))
            }
            if destination.volume.format.isWindowsNative,
               let awkward = plan.files.first(where: { Self.isAwkwardOnWindows($0.relativePath) }) {
                issues.append(.init(code: "windows-name", severity: .warning,
                                    message: "\(awkward.relativePath) uses characters Windows will not open. It copies and verifies correctly onto \(destination.label); only opening it later on a Windows PC is affected."))
            }
            if let maximum = destination.volume.format.maximumFileSize,
               let oversized = plan.files.first(where: { $0.byteCount > maximum }) {
                issues.append(.init(code: "file-too-large", severity: .blocking,
                                    message: "\(oversized.relativePath) is \(oversized.byteCount.formatted(.byteCount(style: .file))), and \(destination.label) is FAT-formatted, which cannot store a file of 4 GB or more however much space is free. Reformat \(destination.label) as exFAT or APFS, or choose another destination."))
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

    /// exFAT and FAT store these names byte-identical, and macOS writes them to
    /// both formats without complaint — measured on freshly created images of
    /// each. What refuses them is Windows, later, on another machine. That is a
    /// portability caveat about a different operating system, not a fact about
    /// whether this copy can be written and verified here, so it warns instead of
    /// blocking: only the user knows whether the drive is bound for a PC.
    private static func isAwkwardOnWindows(_ relativePath: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "<>:\"\\|?*")
        return relativePath.split(separator: "/").contains { component in
            component.rangeOfCharacter(from: forbidden) != nil
                || component.hasSuffix(".") || component.hasSuffix(" ")
        }
    }

    static func isReadable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
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

    /// Network storage is a property of a destination, never of its position in the list.
    ///
    /// The rule this replaced blocked any network Primary, which made a NAS-only archive
    /// impossible to run at all: the user with no local disk to spare had to stage a copy they
    /// did not want. The claim CardVault makes is that a copy was verified, and verification
    /// over a share is real — the read-back closes the file and reopens it, which NFS and SMB
    /// both answer from the server rather than from the client's cache. What the user is owed
    /// is the standing dependency on that server, which is a warning, not a refusal.
    private func networkIssues(destinations: [DestinationPlan]) -> [PreflightIssue] {
        var issues = destinations.filter { !$0.volume.isLocal }.map { destination in
            PreflightIssue(code: "network-destination", severity: .warning,
                           message: "\(destination.label) is on network storage. Its copy is verified by reading it back from the server, so keep the share mounted until copying and verification finish.")
        }
        // Said once, about the transfer, because it is not true of any one destination: each
        // copy is verified, and none of them is on a disk attached to this Mac.
        if !destinations.isEmpty, destinations.allSatisfy({ !$0.volume.isLocal }) {
            issues.append(.init(code: "network-only", severity: .warning,
                                message: "Every copy of this transfer will be on network storage. Each one is verified by reading it back from the server, and the card is safe to eject once that finishes — but no copy will be on a disk attached to this Mac."))
        }
        return issues
    }

    private func independenceIssues(destinations: [DestinationPlan],
                                    availableBytes: [Int64?]) -> [PreflightIssue] {
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
                case .sameServer:
                    issues.append(sameServerIssue(one, other, oneBytes: availableBytes[first],
                                                  otherBytes: availableBytes[second]))
                case .distinct, .indeterminate:
                    break
                }
            }
        }
        return issues
    }

    /// Two shares on one NAS are not two independent copies of anything: one machine, one power
    /// supply, and one pool if the exports happen to share it.
    ///
    /// It warns rather than blocks because the stronger claim is not CardVault's to make. A NAS
    /// with a fast pool and a bulk pool exported side by side is a real configuration and a
    /// genuinely independent pair, and a block would refuse it. So this reports what was
    /// observed — the host, and whether the export path and the free space match — and leaves
    /// the conclusion to the user, who can see the server's disks and CardVault cannot.
    private func sameServerIssue(_ one: DestinationPlan, _ other: DestinationPlan,
                                 oneBytes: Int64?, otherBytes: Int64?) -> PreflightIssue {
        let host = one.volume.networkOrigin?.host ?? "the same server"
        var observed: [String] = []
        let prefix = one.volume.networkOrigin?.exportPrefix
        if let prefix, prefix == other.volume.networkOrigin?.exportPrefix {
            observed.append("are exported from the same path (\(prefix))")
        }
        if let bytes = oneBytes, bytes == otherBytes {
            observed.append("report the same free space (\(bytes.formatted(.byteCount(style: .file))))")
        }
        var message = "\(one.label) and \(other.label) are both on \(host)."
        if !observed.isEmpty {
            message += " They \(observed.formatted(.list(type: .and)))."
        }
        message += observed.count == 2
            ? " One pool exported twice looks exactly like that, and CardVault cannot see the server's disks to tell it apart from two separate pools."
            : " CardVault cannot see how that server stores them, so it cannot confirm these are two independent copies."
        return .init(code: "same-server", severity: .warning, message: message)
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

    /// Two source names that differ only in case become one file on a
    /// case-insensitive destination, so one photograph would silently stand in
    /// for two. The question is asked of the mount itself: case sensitivity is
    /// not something the volume kind reports — APFS and HFS+ each come in both
    /// variants — and a mount that will not answer is treated as insensitive,
    /// because refusing a transfer that would have worked costs less than
    /// finalising one file where the card held two.
    private func collisionIssues(files: [SourceFile], destinations: [DestinationPlan]) -> [PreflightIssue] {
        let folded = Dictionary(grouping: files, by: { $0.relativePath.folding(options: [.caseInsensitive], locale: nil) })
        guard let colliding = folded.values.first(where: { Set($0.map(\.relativePath)).count > 1 }) else { return [] }
        let insensitive = destinations.filter {
            caseSensitivityProvider(URL(filePath: $0.rootPath, directoryHint: .isDirectory)) != true
        }
        guard !insensitive.isEmpty else { return [] }
        let names = Set(colliding.map(\.relativePath)).sorted()
        return [.init(code: "case-collision", severity: .blocking,
                      message: "\(names[0]) and \(names[1]) differ only in case, and \(insensitive.map(\.label).joined(separator: " and ")) would store them as one file. Copy them separately, or choose a destination that keeps names differing only in case apart.")]
    }

    /// Measured at the destination root rather than inferred from its label.
    private static func supportsCaseSensitiveNames(at url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames
    }
}
