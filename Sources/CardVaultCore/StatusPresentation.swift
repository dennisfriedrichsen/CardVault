import Foundation

/// The states CardVault's main screen can principally be in, named so they can
/// be captured, audited, and asserted on.
///
/// This is a presentation vocabulary, not a second state machine:
/// `TransferStateMachine` still owns which transitions are legal. These cases
/// exist because several distinct things the user must be able to tell apart
/// collapse onto the same `TransferState` — a copy that has finished and a
/// transfer that has finished are both "copyComplete" to the coordinator, and a
/// fully verified transfer and one whose backup failed are both "safeToEject".
public enum PrincipalUIState: String, CaseIterable, Sendable {
    case noSource
    case sourceDetected
    case scanning
    case noTransferableFiles
    case ready
    case preflightWarning
    case preflightBlocked
    case copying
    case copyCompleteVerificationPending
    case verifying
    case finalizing
    case verified
    case primaryVerifiedBackupIncomplete
    case conflictPaused
    case interrupted
    case cancelled
    case needsAttention
    case failed
    case safeToEject
    case ejected
}

/// How urgent a status is. Tone reaches the view as colour *only*; the symbol and
/// the words carry the same distinction on their own, because a user who cannot
/// separate the colours must still be able to separate the states.
public enum StatusTone: String, Sendable, CaseIterable {
    case neutral
    case inProgress
    case attention
    case blocked
    case success
}

/// Everything the UI needs to render one status, in one place, so that what the
/// screen shows and what VoiceOver says cannot drift apart.
public struct StatusPresentation: Sendable, Equatable {
    public let state: PrincipalUIState
    /// The headline. Also what `AppModel.message` shows.
    public let title: String
    /// The standing explanation under the headline. Never a restatement of the
    /// title: it carries the promise the title implies.
    public let detail: String
    public let symbolName: String
    public let tone: StatusTone
    /// Spoken once when the app *enters* this state. Status changes are
    /// otherwise silent to VoiceOver, which is how a user misses "do not remove
    /// the card yet".
    public let announcement: String

    /// The header is one combined element, so it needs one sentence that reads
    /// correctly on its own.
    public var accessibilityLabel: String { "\(title). \(detail)" }

    public init(state: PrincipalUIState, title: String, detail: String,
                symbolName: String, tone: StatusTone, announcement: String) {
        self.state = state
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.tone = tone
        self.announcement = announcement
    }
}

extension StatusPresentation {
    /// The never-changing promise about the source, shown whenever nothing more
    /// specific applies.
    public static let sourcePolicyDetail = "CardVault reads the source and never changes it."
    /// Shown wherever ejection is offered. CardVault does not have an opinion
    /// about erasing a card, and says so rather than staying silent.
    public static let ejectionDetail = "Safe to eject does not mean safe to erase."

    /// Pure mapping. `conflictCount` only fills in a number the user is owed; no
    /// other input can change which state is described.
    public static func `for`(_ state: PrincipalUIState, conflictCount: Int = 0) -> StatusPresentation {
        switch state {
        case .noSource:
            StatusPresentation(
                state: state,
                title: "Choose an SD card or source folder to begin.",
                detail: sourcePolicyDetail,
                symbolName: "sdcard",
                tone: .neutral,
                announcement: "No source selected. Choose an SD card or source folder to begin.")
        case .sourceDetected:
            StatusPresentation(
                state: state,
                title: "Removable card detected",
                detail: "Choose it as the source to scan it. Nothing is read until you do.",
                symbolName: "sdcard.fill",
                tone: .neutral,
                announcement: "A removable card was detected. Choose it as the source to scan it.")
        case .scanning:
            StatusPresentation(
                state: state,
                title: "Scanning source without modifying it…",
                detail: sourcePolicyDetail,
                symbolName: "magnifyingglass",
                tone: .inProgress,
                announcement: "Scanning the source. Nothing is being modified.")
        case .noTransferableFiles:
            StatusPresentation(
                state: state,
                title: "No transferable files found.",
                detail: "The source was read and left unchanged. Check the mode, or choose another source.",
                symbolName: "questionmark.folder",
                tone: .attention,
                announcement: "No transferable files were found. The source was left unchanged.")
        case .ready:
            StatusPresentation(
                state: state,
                title: "Ready to transfer",
                detail: "Preflight found nothing that stops this transfer.",
                symbolName: "checkmark.circle",
                tone: .neutral,
                announcement: "Ready to transfer. Preflight found nothing that stops this transfer.")
        case .preflightWarning:
            StatusPresentation(
                state: state,
                title: "Ready to transfer, with warnings",
                detail: "Warnings do not stop the transfer. Read them before you start.",
                symbolName: "exclamationmark.triangle.fill",
                tone: .attention,
                announcement: "Ready to transfer, with warnings. Read the preflight warnings before you start.")
        case .preflightBlocked:
            StatusPresentation(
                state: state,
                title: "Cannot start — preflight found a blocking problem",
                detail: "Resolve the blocking problem to continue. Nothing has been copied.",
                symbolName: "exclamationmark.octagon.fill",
                tone: .blocked,
                announcement: "Cannot start. Preflight found a blocking problem. Nothing has been copied.")
        case .copying:
            StatusPresentation(
                state: state,
                title: "Copying — do not remove card yet",
                detail: sourcePolicyDetail,
                symbolName: "doc.on.doc.fill",
                tone: .inProgress,
                announcement: "Copying. Do not remove the card yet.")
        case .copyCompleteVerificationPending:
            StatusPresentation(
                state: state,
                title: "Copy complete — verifying, do not remove card yet",
                // A finished copy is the most dangerous moment to look finished.
                detail: "A finished copy is not a finished transfer. Verification decides.",
                symbolName: "hourglass.circle.fill",
                tone: .inProgress,
                announcement: "Copy complete. Verification has not finished. Do not remove the card yet.")
        case .verifying:
            StatusPresentation(
                state: state,
                title: "Verifying copied files — do not remove card yet",
                detail: "Every copy is read back and checksummed against the source.",
                symbolName: "checkmark.shield",
                tone: .inProgress,
                announcement: "Verifying copied files. Do not remove the card yet.")
        case .finalizing:
            StatusPresentation(
                state: state,
                title: "Finalizing verified transfer",
                detail: "The verified copy is being moved into its final place on the destination.",
                symbolName: "hourglass",
                tone: .inProgress,
                announcement: "Finalizing the verified transfer.")
        case .verified:
            StatusPresentation(
                state: state,
                title: "Transfer fully verified — Safe to eject",
                detail: ejectionDetail,
                symbolName: "checkmark.seal.fill",
                tone: .success,
                announcement: "Transfer fully verified. Safe to eject. Safe to eject does not mean safe to erase.")
        case .primaryVerifiedBackupIncomplete:
            StatusPresentation(
                state: state,
                // A verified primary must never read as a finished transfer while
                // a destination is still unverified.
                title: "Primary verified — Backup incomplete",
                detail: "One destination is verified and one is not. Both results are shown separately.",
                symbolName: "externaldrive.badge.exclamationmark",
                tone: .attention,
                announcement: "Primary destination verified. Backup destination incomplete. Check each destination's result.")
        case .conflictPaused:
            StatusPresentation(
                state: state,
                title: conflictCount == 1
                    ? "Paused — 1 file needs a decision"
                    : "Paused — \(conflictCount) files need a decision",
                detail: "Nothing was overwritten and nothing was renamed. The source was not changed.",
                symbolName: "hand.raised.fill",
                tone: .attention,
                announcement: conflictCount == 1
                    ? "Paused. 1 file needs a decision. Nothing was overwritten or renamed."
                    : "Paused. \(conflictCount) files need a decision. Nothing was overwritten or renamed.")
        case .interrupted:
            StatusPresentation(
                state: state,
                title: "Transfer interrupted — Safe to eject",
                detail: "What was verified stays verified. The unfinished part can be resumed.",
                symbolName: "bolt.horizontal.circle.fill",
                tone: .attention,
                announcement: "Transfer interrupted. The card is safe to eject and the transfer can be resumed.")
        case .cancelled:
            StatusPresentation(
                state: state,
                // Named for who stopped it. An interrupted transfer is something
                // that happened to the user; this one is something they chose,
                // and the difference decides whether they go looking for a fault.
                title: "Transfer stopped — Safe to eject",
                detail: "Every file already verified stays verified, and the source was not changed. The rest can be resumed.",
                symbolName: "stop.circle.fill",
                tone: .attention,
                announcement: "Transfer stopped. Every file already verified stays verified, the source was not changed, and the card is safe to eject.")
        case .needsAttention:
            StatusPresentation(
                state: state,
                title: "Transfer needs attention",
                detail: "The source was not modified. Inspect the incomplete destination and try again.",
                symbolName: "exclamationmark.circle.fill",
                tone: .attention,
                announcement: "Transfer needs attention. The source was not modified.")
        case .failed:
            StatusPresentation(
                state: state,
                title: "Transfer failed",
                detail: "No destination was verified. The source was not modified.",
                symbolName: "xmark.octagon.fill",
                tone: .blocked,
                announcement: "Transfer failed. No destination was verified. The source was not modified.")
        case .safeToEject:
            StatusPresentation(
                state: state,
                title: "Safe to eject",
                detail: ejectionDetail,
                symbolName: "eject.fill",
                tone: .success,
                announcement: "Safe to eject. Safe to eject does not mean safe to erase.")
        case .ejected:
            StatusPresentation(
                state: state,
                // The card is out and its transfer is recorded, so this screen
                // is the start of the next transfer, not the end of the last.
                title: "Card ejected — ready for the next transfer",
                detail: "The transfer's record is in History. The card was left exactly as it was found.",
                symbolName: "eject.circle.fill",
                tone: .success,
                announcement: "Card ejected. Ready for the next transfer. The transfer's record is in History, and the card was left exactly as it was found.")
        }
    }
}
