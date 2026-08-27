import Foundation
import Testing
@testable import CardVaultCore

@Suite("Persisted selections")
struct PreferenceTests {
    /// A suite of its own per test, so a stored preference cannot leak between
    /// tests or into the developer's own defaults.
    private func withDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "CardVaultTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return try body(defaults)
    }

    private func withPreference<T>(_ body: (TransferModePreference) throws -> T) rethrows -> T {
        try withDefaults { try body(TransferModePreference(defaults: $0)) }
    }

    @Test func modeDefaultsToPreserveCardWhenNothingIsStored() {
        withPreference { #expect($0.load() == .preserveCard) }
    }

    @Test func modeSurvivesRelaunch() {
        withPreference { preference in
            for mode in TransferMode.allCases {
                preference.save(mode)
                #expect(preference.load() == mode)
            }
        }
    }

    /// A mode this build no longer offers must not leave the picker holding a
    /// value the app cannot act on.
    @Test func unknownStoredModeFallsBackToTheDefault() {
        let name = "CardVaultTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("modeFromAnotherBuild", forKey: "transferMode")
        #expect(TransferModePreference(defaults: defaults).load() == .preserveCard)
    }

    @Test func fullPathDisplayIsOffUntilItIsTurnedOn() {
        withDefaults { #expect(FullPathDisplayPreference(defaults: $0).load() == false) }
    }

    @Test func fullPathDisplaySurvivesRelaunch() {
        withDefaults { defaults in
            for showsFullPaths in [true, false, true] {
                FullPathDisplayPreference(defaults: defaults).save(showsFullPaths)
                #expect(FullPathDisplayPreference(defaults: defaults).load() == showsFullPaths)
            }
        }
    }

    @Test func shortLabelIsTheFolderName() {
        #expect(PathDisplay.label(for: URL(filePath: "/Volumes/Archive/tmp", directoryHint: .isDirectory),
                                  showsFullPath: false) == "tmp")
    }

    /// The point of the setting: two folders that share a name have to read
    /// differently once it is on.
    @Test func fullLabelsSeparateFoldersThatShareAName() {
        let onCard = URL(filePath: "/Volumes/Archive/tmp", directoryHint: .isDirectory)
        let onDisk = URL(filePath: "/Volumes/Backup/staging/tmp", directoryHint: .isDirectory)
        #expect(PathDisplay.label(for: onCard, showsFullPath: true) == "/Volumes/Archive/tmp")
        #expect(PathDisplay.label(for: onCard, showsFullPath: true)
                != PathDisplay.label(for: onDisk, showsFullPath: true))
    }

    @Test func fullLabelAbbreviatesTheHomeDirectory() {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            .appending(path: "Pictures/tmp", directoryHint: .isDirectory)
        #expect(PathDisplay.label(for: home, showsFullPath: true) == "~/Pictures/tmp")
    }
}
