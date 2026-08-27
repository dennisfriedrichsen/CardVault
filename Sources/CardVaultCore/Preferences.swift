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

/// Whether folders are named on screen by their full path rather than by their
/// last path component alone. The short name is what the user recognizes, so it
/// stays the default; but names are not unique, and a user with three folders
/// called `tmp` cannot tell from the name which one a transfer will write to.
public struct FullPathDisplayPreference {
    private static let key = "showsFullPaths"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// False when nothing is stored: the short name is the better default for
    /// the common case of folders whose names already differ.
    public func load() -> Bool { defaults.bool(forKey: Self.key) }

    public func save(_ showsFullPaths: Bool) {
        defaults.set(showsFullPaths, forKey: Self.key)
    }
}

/// How a folder is named on screen. One definition, so every screen that names a
/// folder answers the setting the same way: a screen that kept naming folders
/// its own way would preserve the ambiguity the setting exists to remove.
public enum PathDisplay {
    public static func label(for url: URL, showsFullPath: Bool) -> String {
        guard showsFullPath else { return url.lastPathComponent }
        // Abbreviated at the home directory: `~/Pictures/tmp` separates that
        // folder from every other `tmp` just as well as the absolute path does,
        // and still fits the card it is shown in.
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
