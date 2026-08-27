import Foundation
import Testing
@testable import CardVaultCore

@Suite("Persisted selections")
struct PreferenceTests {
    /// A suite of its own per test, so a stored preference cannot leak between
    /// tests or into the developer's own defaults.
    private func withPreference<T>(_ body: (TransferModePreference) throws -> T) rethrows -> T {
        let name = "CardVaultTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return try body(TransferModePreference(defaults: defaults))
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
}
