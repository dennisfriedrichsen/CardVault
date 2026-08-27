import Foundation

/// Selections that outlive a launch but are not durable truth about any
/// transfer. The mode belongs here for the same reason the destination
/// bookmarks are stored: a setup the user deliberately chose must not revert to
/// the default on the next launch, because that revert is silent and the wrong
/// mode reads the wrong files off a card.
public struct TransferModePreference {
    private static let key = "transferMode"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored mode, or the recommended default when nothing is stored or
    /// the stored value is not a mode this build offers.
    public func load() -> TransferMode {
        guard let raw = defaults.string(forKey: Self.key),
              let mode = TransferMode(rawValue: raw) else { return .preserveCard }
        return mode
    }

    public func save(_ mode: TransferMode) {
        defaults.set(mode.rawValue, forKey: Self.key)
    }
}
