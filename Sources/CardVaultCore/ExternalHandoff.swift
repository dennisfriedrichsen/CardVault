import Foundation

/// A companion application CardVault can hand a finished destination to.
/// Handoff is optional in every sense that matters: CardVault does not require
/// the app, does not install it, does not depend on what it does with the
/// folder, and never treats its presence or absence as part of a transfer's
/// result. Nothing is copied, moved, or deleted by handing off.
public struct HandoffTarget: Sendable, Hashable {
    public let displayName: String
    /// Candidate bundle identifiers, tried in order. A list rather than one
    /// value so a rename or a differently-signed build does not silently turn
    /// the action off.
    public let bundleIdentifiers: [String]

    public init(displayName: String, bundleIdentifiers: [String]) {
        self.displayName = displayName
        self.bundleIdentifiers = bundleIdentifiers
    }

    public static let sdelight = HandoffTarget(
        displayName: "SDelight",
        bundleIdentifiers: ["com.dennisfriedrichsen.SDelight", "com.sdelight.SDelight"])
}

/// Service boundary over the installed-application lookup, so handoff rules are
/// testable without installing anything.
public protocol ExternalApplicationLocator: Sendable {
    func applicationURL(forBundleIdentifier identifier: String) -> URL?
}

/// Whether a destination can be handed off right now, and if not, why not. The
/// reason is written to be shown to the user, because an action that is merely
/// disabled tells them nothing.
public enum HandoffAvailability: Sendable, Equatable {
    case ready(applicationURL: URL)
    case applicationNotInstalled(String)
    case destinationUnavailable(String)
    case destinationNotVerified(String)

    public var isReady: Bool { applicationURL != nil }

    public var applicationURL: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }

    /// Why the action is unavailable, or nil when it is available.
    public var explanation: String? {
        switch self {
        case .ready: nil
        case .applicationNotInstalled(let text), .destinationUnavailable(let text),
             .destinationNotVerified(let text): text
        }
    }
}

/// Decides whether one past destination may be handed to a companion app.
/// Deliberately strict: only a destination that is connected *and* whose every
/// file was independently verified is offered, because a handoff is an
/// invitation to treat those files as the good copy.
public struct ExternalAppHandoff: Sendable {
    public let target: HandoffTarget
    private let locator: any ExternalApplicationLocator

    public init(target: HandoffTarget = .sdelight, locator: any ExternalApplicationLocator) {
        self.target = target
        self.locator = locator
    }

    public func availability(for status: HistoryDestinationStatus) -> HandoffAvailability {
        guard status.transferRoot != nil else {
            return .destinationUnavailable(
                "\(target.displayName) can only open a destination that is connected. "
                + (status.revealUnavailableReason ?? ""))
        }
        guard status.isVerified else {
            return .destinationNotVerified(
                "\(status.label) was not fully verified, so CardVault does not offer it to \(target.displayName). "
                + status.verificationSummary)
        }
        guard let applicationURL = target.bundleIdentifiers
            .lazy.compactMap({ locator.applicationURL(forBundleIdentifier: $0) }).first else {
            return .applicationNotInstalled("\(target.displayName) is not installed on this Mac.")
        }
        return .ready(applicationURL: applicationURL)
    }
}
