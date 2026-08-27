import Foundation

/// A complete, deterministic set of core values that puts the UI into one
/// `PrincipalUIState` without a card, a drive, or an injected fault.
///
/// These live in the core rather than the app target for two reasons: the values
/// are the core's own types, and the tests that assert the audit's conclusions
/// have to be able to read exactly what the screenshots were taken from. Every
/// date, count and byte total here is fixed, so two captures of the same state
/// differ only if the UI changed.
public struct UIStateFixture: Sendable, Identifiable {
    public var id: String { state.rawValue }
    public let state: PrincipalUIState
    public let transferName: String
    public let mode: TransferMode
    public let sourceVolume: VolumeIdentity?
    public let sourcePath: String?
    public let destinationName: String?
    public let backupName: String?
    public let detectedVolumes: [MountedVolume]
    public let scan: ScanResult?
    public let preflight: PreflightResult?
    public let copyProgress: TransferProgress?
    public let verificationProgress: TransferProgress?
    public let isFinalizing: Bool
    /// True for the states where CardVault is mid-operation. The UI hides actions
    /// it would only refuse, so a capture that got this wrong would show a
    /// screen the user never sees.
    public let isWorking: Bool
    public let outcome: TransferOutcome?
    /// Only the interrupted fixture carries one: the recovery sheet is the state,
    /// not a decoration on it.
    public let recovery: RecoveryScan?

    public var presentation: StatusPresentation {
        StatusPresentation.for(state, conflictCount: outcome?.conflicts.count ?? 0)
    }
}

extension UIStateFixture {
    public static var all: [UIStateFixture] { PrincipalUIState.allCases.map(fixture(for:)) }

    public static func fixture(for state: PrincipalUIState) -> UIStateFixture {
        switch state {
        // Nothing has been chosen yet, so neither destination is set either.
        case .noSource:
            return base(state, sourceVolume: nil, sourcePath: nil, scan: nil, preflight: nil,
                        destinationName: nil, backupName: nil, detectedVolumes: [])
        case .sourceDetected:
            return base(state, sourceVolume: nil, sourcePath: nil, scan: nil, preflight: nil,
                        destinationName: nil, backupName: nil)
        case .scanning:
            return base(state, scan: nil, preflight: nil)
        case .noTransferableFiles:
            return base(state, scan: emptyScanResult, preflight: nil)
        case .ready:
            return base(state, preflight: readyPreflight)
        case .preflightWarning:
            return base(state, preflight: warningPreflight)
        case .preflightBlocked:
            return base(state, preflight: blockedPreflight)
        case .copying:
            return base(state, copyProgress: copyingProgress)
        case .copyCompleteVerificationPending:
            return base(state, copyProgress: copyCompleteProgress)
        case .verifying:
            return base(state, copyProgress: copyCompleteProgress, verificationProgress: verifyingProgress)
        case .finalizing:
            return base(state, copyProgress: copyCompleteProgress, verificationProgress: verifiedProgress,
                        isFinalizing: true)
        case .verified:
            return base(state, copyProgress: copyCompleteProgress, verificationProgress: verifiedProgress,
                        outcome: verifiedOutcome)
        case .primaryVerifiedBackupIncomplete:
            return base(state, copyProgress: copyCompleteProgress, verificationProgress: verifiedProgress,
                        outcome: partialOutcome)
        case .conflictPaused:
            return base(state, copyProgress: pausedCopyProgress, outcome: conflictOutcome)
        case .interrupted:
            return base(state, copyProgress: pausedCopyProgress, recovery: interruptedScan)
        // What is left on screen once the recovery sheet the stop raised has
        // been dismissed: the partial copy, and no outcome, because the
        // transfer produced no result to report.
        case .cancelled:
            return base(state, copyProgress: pausedCopyProgress)
        case .needsAttention:
            return base(state, copyProgress: pausedCopyProgress, outcome: needsAttentionOutcome)
        case .failed:
            return base(state, copyProgress: pausedCopyProgress, outcome: failedOutcome)
        case .safeToEject:
            return base(state, copyProgress: copyCompleteProgress, verificationProgress: verifiedProgress,
                        outcome: verifiedOutcome)
        // The card is gone, so everything that described it is gone with it. The
        // destinations stay: they are the user's standing choice, not the
        // finished transfer's.
        case .ejected:
            return base(state, sourceVolume: nil, sourcePath: nil, scan: nil, preflight: nil,
                        detectedVolumes: [])
        }
    }

    // MARK: - Shared world

    /// Fixed so that a capture only changes when the UI changes.
    public static let referenceDate = Date(timeIntervalSince1970: 1_756_000_000)
    public static let primaryDestinationID = UUID(uuidString: "1D9F1F5E-0000-4000-A000-000000000001")!
    public static let backupDestinationID = UUID(uuidString: "1D9F1F5E-0000-4000-A000-000000000002")!
    public static let transferID = UUID(uuidString: "1D9F1F5E-0000-4000-A000-0000000000FF")!

    public static let cardVolume = VolumeIdentity(
        volumeUUID: UUID(uuidString: "8B0B4E3E-0000-4000-A000-00000000CA11"),
        resourceIdentifier: "disk4s1", displayName: "EOS_DIGITAL", fileSystem: "exFAT",
        isRemovable: true, isLocal: true, physicalStoreIdentifier: "disk4",
        partitionIdentifier: "disk4s1", identitySource: .diskArbitration)

    public static let primaryVolume = VolumeIdentity(
        volumeUUID: UUID(uuidString: "8B0B4E3E-0000-4000-A000-000000000A01"),
        resourceIdentifier: "disk5s2", displayName: "Field Archive", fileSystem: "APFS",
        isRemovable: false, isLocal: true, identitySource: .diskArbitration)

    public static let backupVolume = VolumeIdentity(
        volumeUUID: UUID(uuidString: "8B0B4E3E-0000-4000-A000-000000000B02"),
        resourceIdentifier: "disk6s2", displayName: "Backup Shuttle", fileSystem: "APFS",
        isRemovable: true, isLocal: true, identitySource: .diskArbitration)

    public static let sourceFiles: [SourceFile] = {
        let names = ["IMG_0431", "IMG_0432", "IMG_0433", "IMG_0434", "IMG_0435", "IMG_0436"]
        var files: [SourceFile] = names.enumerated().flatMap { index, name -> [SourceFile] in
            [SourceFile(relativePath: "DCIM/100EOS_R/\(name).CR3",
                        byteCount: 41_943_040 + Int64(index) * 262_144,
                        creationDate: referenceDate, modificationDate: referenceDate, mediaKind: .raw),
             SourceFile(relativePath: "DCIM/100EOS_R/\(name).JPG",
                        byteCount: 8_388_608 + Int64(index) * 65_536,
                        creationDate: referenceDate, modificationDate: referenceDate, mediaKind: .jpeg)]
        }
        files.append(SourceFile(relativePath: "PRIVATE/M4ROOT/CLIP/C0007.MP4", byteCount: 2_147_483_648,
                                creationDate: referenceDate, modificationDate: referenceDate, mediaKind: .video))
        return files
    }()

    public static let scanResult = ScanResult(
        files: sourceFiles,
        excludedFiles: [SourceFile(relativePath: ".Spotlight-V100/store.db", byteCount: 24_576,
                                   creationDate: referenceDate, modificationDate: referenceDate, mediaKind: .other)],
        rawJPEGPairCount: 6)

    /// A source that scanned cleanly and holds nothing CardVault would move.
    public static let emptyScanResult = ScanResult(
        files: [],
        excludedFiles: [SourceFile(relativePath: ".Spotlight-V100/store.db", byteCount: 24_576,
                                   creationDate: referenceDate, modificationDate: referenceDate, mediaKind: .other)],
        rawJPEGPairCount: 0)

    public static let detectedCard = MountedVolume(
        url: URL(filePath: "/Volumes/EOS_DIGITAL", directoryHint: .isDirectory), identity: cardVolume)

    // MARK: - Preflight

    /// The preflight fixtures are the output of the real check, not hand-written
    /// `PreflightIssue` values. Posing them by hand let them drift until every
    /// message in the reference set described a check `Preflight.swift` does not
    /// perform — the audit's baseline was a picture of an app that does not
    /// exist. Deriving them means a wording change reaches the fixtures with the
    /// code, and an invented warning cannot be posed at all.
    ///
    /// This does no I/O: both of `validate`'s probes are injected, so the result
    /// is a pure function of the plan below.
    private static func preflight(_ plan: TransferPlan,
                                  capacity: @escaping @Sendable (URL) -> Int64?) -> PreflightResult {
        TransferPreflightService(capacityProvider: capacity, readabilityProvider: { _ in true })
            .validate(plan)
    }

    private static let primaryRootPath = "/Volumes/Field Archive/Transfers"
    private static let backupRootPath = "/Volumes/Backup Shuttle/Transfers"

    private static func plan(primary: VolumeIdentity, backup: VolumeIdentity) -> TransferPlan {
        TransferPlan(id: transferID, name: "2026-08-26", mode: .preserveCard,
                     sourceRootPath: "/Volumes/EOS_DIGITAL", sourceVolume: cardVolume,
                     files: sourceFiles,
                     destinations: [DestinationPlan(id: primaryDestinationID, label: "Primary",
                                                    rootPath: primaryRootPath, volume: primary),
                                    DestinationPlan(id: backupDestinationID, label: "Backup",
                                                    rootPath: backupRootPath, volume: backup)])
    }

    /// Two partitions of one physical device. This is the warning worth showing:
    /// both copies land on the same disk, so a single failure takes both, and
    /// nothing about the paths says so.
    private static let sharedDeviceBackupVolume = VolumeIdentity(
        volumeUUID: UUID(uuidString: "8B0B4E3E-0000-4000-A000-000000000B03"),
        resourceIdentifier: "disk5s3", displayName: "Backup Shuttle", fileSystem: "APFS",
        isRemovable: false, isLocal: true, physicalStoreIdentifier: "disk5",
        partitionIdentifier: "disk5s3", identitySource: .diskArbitration)

    private static let independentPrimaryVolume = VolumeIdentity(
        volumeUUID: primaryVolume.volumeUUID, resourceIdentifier: "disk5s2",
        displayName: "Field Archive", fileSystem: "APFS", isRemovable: false, isLocal: true,
        physicalStoreIdentifier: "disk5", partitionIdentifier: "disk5s2",
        identitySource: .diskArbitration)

    private static let roomyCapacity: @Sendable (URL) -> Int64? = { url in
        url.path == primaryRootPath ? 812_000_000_000 : 240_000_000_000
    }

    static let readyPreflight = preflight(plan(primary: primaryVolume, backup: backupVolume),
                                          capacity: roomyCapacity)

    /// `same-device`: the destinations are independent folders on one disk.
    static let warningPreflight = preflight(
        plan(primary: independentPrimaryVolume, backup: sharedDeviceBackupVolume),
        capacity: roomyCapacity)

    /// `insufficient-space` on the primary, with the `same-device` warning still
    /// standing behind it — so the blocked state shows both severities at once,
    /// which is the layout the audit is actually checking.
    static let blockedPreflight = preflight(
        plan(primary: independentPrimaryVolume, backup: sharedDeviceBackupVolume),
        capacity: { url in url.path == primaryRootPath ? 1_073_741_824 : 240_000_000_000 })

    // MARK: - Progress

    private static var workBytes: Int64 { scanResult.totalBytes * 3 }

    static let copyingProgress = TransferProgress(
        phase: .copying, completedFiles: 5, totalFiles: 13,
        completedBytes: workBytes * 2 / 5, totalBytes: workBytes,
        currentRelativePath: "DCIM/100EOS_R/IMG_0433.CR3",
        bytesPerSecond: 96_000_000, estimatedSecondsRemaining: 74, elapsedSeconds: 48)

    static let copyCompleteProgress = TransferProgress(
        phase: .copying, completedFiles: 13, totalFiles: 13,
        completedBytes: workBytes, totalBytes: workBytes,
        currentRelativePath: "PRIVATE/M4ROOT/CLIP/C0007.MP4",
        bytesPerSecond: 101_000_000, estimatedSecondsRemaining: 0, elapsedSeconds: 122)

    /// A copy stopped partway: what the interrupted, paused and failed states
    /// legitimately have in common is that the copy bar is not full.
    static let pausedCopyProgress = TransferProgress(
        phase: .copying, completedFiles: 7, totalFiles: 13,
        completedBytes: workBytes * 3 / 5, totalBytes: workBytes,
        currentRelativePath: "DCIM/100EOS_R/IMG_0435.CR3",
        bytesPerSecond: 88_000_000, estimatedSecondsRemaining: 51, elapsedSeconds: 96)

    static let verifyingProgress = TransferProgress(
        phase: .verifying, completedFiles: 6, totalFiles: 13,
        completedBytes: workBytes * 2 / 5, totalBytes: workBytes,
        currentRelativePath: "DCIM/100EOS_R/IMG_0434.JPG",
        bytesPerSecond: 210_000_000, estimatedSecondsRemaining: 33, elapsedSeconds: 29)

    static let verifiedProgress = TransferProgress(
        phase: .verifying, completedFiles: 13, totalFiles: 13,
        completedBytes: workBytes, totalBytes: workBytes,
        currentRelativePath: nil,
        bytesPerSecond: 214_000_000, estimatedSecondsRemaining: 0, elapsedSeconds: 61)

    // MARK: - Outcomes

    private static let primaryURL = URL(filePath: "/Volumes/Field Archive/2026-08-26", directoryHint: .isDirectory)
    private static let backupURL = URL(filePath: "/Volumes/Backup Shuttle/2026-08-26", directoryHint: .isDirectory)

    static let verifiedOutcome = TransferOutcome(
        transferID: transferID, state: .verified,
        destinations: [DestinationOutcome(id: primaryDestinationID, label: "Primary", verifiedFiles: 13,
                                          failedFiles: 0, finalURL: primaryURL),
                       DestinationOutcome(id: backupDestinationID, label: "Backup", verifiedFiles: 13,
                                          failedFiles: 0, finalURL: backupURL)],
        safeToEject: true)

    /// A verified primary never masks a failed backup, so the fixture keeps both
    /// results and the transfer stays `partiallySuccessful`.
    static let partialOutcome = TransferOutcome(
        transferID: transferID, state: .partiallySuccessful,
        destinations: [DestinationOutcome(id: primaryDestinationID, label: "Primary", verifiedFiles: 13,
                                          failedFiles: 0, finalURL: primaryURL),
                       DestinationOutcome(id: backupDestinationID, label: "Backup", verifiedFiles: 9,
                                          failedFiles: 4, finalURL: nil)],
        safeToEject: true)

    static let needsAttentionOutcome = TransferOutcome(
        transferID: transferID, state: .needsAttention,
        destinations: [DestinationOutcome(id: primaryDestinationID, label: "Primary", verifiedFiles: 7,
                                          failedFiles: 6, finalURL: nil)],
        safeToEject: true)

    static let failedOutcome = TransferOutcome(
        transferID: transferID, state: .failed,
        destinations: [DestinationOutcome(id: primaryDestinationID, label: "Primary", verifiedFiles: 0,
                                          failedFiles: 13, finalURL: nil)],
        safeToEject: true)

    static let conflictOutcome = TransferOutcome(
        transferID: transferID, state: .needsAttention,
        destinations: [DestinationOutcome(id: primaryDestinationID, label: "Primary", verifiedFiles: 7,
                                          failedFiles: 0, finalURL: nil)],
        safeToEject: true,
        conflicts: [DestinationConflict(destinationID: primaryDestinationID, destinationLabel: "Primary",
                                        relativePath: "DCIM/100EOS_R/IMG_0435.CR3",
                                        classification: .differentContent, existingByteCount: 42_205_184,
                                        explanation: "A CardVault record ties this path to different content. Nothing was overwritten."),
                    DestinationConflict(destinationID: primaryDestinationID, destinationLabel: "Primary",
                                        relativePath: "DCIM/100EOS_R/IMG_0436.JPG",
                                        classification: .unrelatedFile, existingByteCount: 8_650_752,
                                        explanation: "No CardVault record covers this file and its content is not the source's.")])

    // MARK: - Recovery

    static let interruptedScan: RecoveryScan = {
        var manifest = TransferManifest(
            plan: TransferPlan(id: transferID, name: "2026-08-26", mode: .preserveCard,
                               sourceRootPath: "/Volumes/EOS_DIGITAL", sourceVolume: cardVolume,
                               files: sourceFiles,
                               destinations: [DestinationPlan(id: primaryDestinationID, label: "Primary",
                                                              rootPath: "/Volumes/Field Archive", volume: primaryVolume),
                                              DestinationPlan(id: backupDestinationID, label: "Backup",
                                                              rootPath: "/Volumes/Backup Shuttle", volume: backupVolume)]),
            applicationVersion: "1.0", now: referenceDate)
        manifest.state = .copying
        manifest.startedAt = referenceDate
        manifest.warnings = ["The backup destination was disconnected during the copy."]
        manifest.files = manifest.files.enumerated().map { index, file in
            var file = file
            file.sourceChecksum = String(repeating: "a", count: 64)
            let verified = index < 7
            file.destinations[primaryDestinationID] = DestinationFileResult(
                copyState: verified ? .copied : .pending,
                verification: verified ? .verified : .pending,
                destinationChecksum: verified ? String(repeating: "a", count: 64) : nil)
            file.destinations[backupDestinationID] = DestinationFileResult(
                copyState: index < 5 ? .copied : .pending,
                verification: index < 5 ? .verified : .pending)
            return file
        }
        let source = RecoveredSource(recordedVolume: cardVolume,
                                     root: URL(filePath: "/Volumes/EOS_DIGITAL", directoryHint: .isDirectory),
                                     match: .matched, bookmarkWasStale: false)
        let destinations = [
            RecoveredDestination(id: primaryDestinationID, label: "Primary", recordedVolume: primaryVolume,
                                 root: URL(filePath: "/Volumes/Field Archive", directoryHint: .isDirectory),
                                 stagingRoot: primaryURL, manifestURL: primaryURL.appending(path: ".cardvault/transfer-manifest.json"),
                                 match: .matched, bookmarkWasStale: false,
                                 copiedFiles: 7, verifiedFiles: 7, conflictedFiles: 0),
            RecoveredDestination(id: backupDestinationID, label: "Backup", recordedVolume: backupVolume,
                                 root: nil, stagingRoot: nil, manifestURL: nil,
                                 match: .unavailable, bookmarkWasStale: false,
                                 copiedFiles: 5, verifiedFiles: 5, conflictedFiles: 0)]
        return RecoveryScan(
            transfers: [RecoverableTransfer(manifest: manifest, source: source, destinations: destinations)],
            unreadable: [])
    }()

    // MARK: - Construction

    private static func base(_ state: PrincipalUIState,
                             sourceVolume: VolumeIdentity? = cardVolume,
                             sourcePath: String? = "/Volumes/EOS_DIGITAL",
                             scan: ScanResult? = scanResult,
                             preflight: PreflightResult? = readyPreflight,
                             destinationName: String? = "Field Archive",
                             backupName: String? = "Backup Shuttle",
                             detectedVolumes: [MountedVolume] = [detectedCard],
                             copyProgress: TransferProgress? = nil,
                             verificationProgress: TransferProgress? = nil,
                             isFinalizing: Bool = false,
                             outcome: TransferOutcome? = nil,
                             recovery: RecoveryScan? = nil) -> UIStateFixture {
        UIStateFixture(state: state, transferName: "2026-08-26", mode: .preserveCard,
                       sourceVolume: sourceVolume, sourcePath: sourcePath,
                       destinationName: destinationName, backupName: backupName,
                       detectedVolumes: detectedVolumes, scan: scan, preflight: preflight,
                       copyProgress: copyProgress, verificationProgress: verificationProgress,
                       isFinalizing: isFinalizing, isWorking: Self.isWorking(in: state),
                       outcome: outcome, recovery: recovery)
    }

    /// The states where an operation is under way. Derived from the state rather
    /// than passed in, so a fixture cannot claim to be copying while idle.
    private static func isWorking(in state: PrincipalUIState) -> Bool {
        switch state {
        case .scanning, .copying, .copyCompleteVerificationPending, .verifying, .finalizing: true
        default: false
        }
    }
}
