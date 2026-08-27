import Foundation
import Testing
@testable import CardVaultCore

/// The conclusions of the UI state audit, written as assertions.
///
/// The audit itself is in `Docs/ui-state-audit.md` and its evidence is the
/// reference set in `Docs/ui-states/`. What can be checked mechanically is
/// checked here, so a later change that quietly reintroduces a colour-only
/// distinction, a silent status, or a "safe to erase" claim fails the build
/// rather than waiting for the next manual pass.
@Suite("Principal UI state presentation")
struct UIStatePresentationTests {

    @Test("Every principal state says something, and says it with a symbol")
    func everyStateIsDescribed() {
        for state in PrincipalUIState.allCases {
            let presentation = StatusPresentation.for(state, conflictCount: 2)
            #expect(!presentation.title.isEmpty, "\(state) has no title")
            #expect(!presentation.detail.isEmpty, "\(state) has no detail")
            #expect(!presentation.symbolName.isEmpty, "\(state) has no symbol")
            #expect(!presentation.announcement.isEmpty, "\(state) announces nothing")
            #expect(presentation.state == state)
        }
    }

    /// The colour-alone criterion, mechanically: two states that share a tone
    /// are rendered in the same colour, so they must differ in both symbol and
    /// wording or they are indistinguishable without colour vision.
    @Test("States sharing a tone are distinguishable without colour")
    func statesAreDistinguishableWithoutColour() {
        let presentations = PrincipalUIState.allCases.map { StatusPresentation.for($0, conflictCount: 2) }
        for tone in StatusTone.allCases {
            let sharing = presentations.filter { $0.tone == tone }
            #expect(Set(sharing.map(\.symbolName)).count == sharing.count,
                    "two \(tone) states share a symbol")
            #expect(Set(sharing.map(\.title)).count == sharing.count,
                    "two \(tone) states share a title")
        }
    }

    @Test("Every state is distinguishable from every other by its words alone")
    func titlesAreUnique() {
        let titles = PrincipalUIState.allCases.map { StatusPresentation.for($0, conflictCount: 2).title }
        #expect(Set(titles).count == titles.count)
    }

    /// The product boundary, asserted: CardVault reports that a card can be
    /// removed, never that it can be wiped. The only permitted mention of
    /// erasing is the sentence that denies it.
    @Test("No status ever suggests the card is safe to erase")
    func neverClaimsSafeToErase() {
        for state in PrincipalUIState.allCases {
            let presentation = StatusPresentation.for(state)
            for text in [presentation.title, presentation.detail, presentation.announcement]
            where text.localizedCaseInsensitiveContains("erase") {
                #expect(text.localizedCaseInsensitiveContains("does not mean safe to erase"),
                        "\(state) mentions erasing outside the disclaimer: \(text)")
            }
        }
    }

    /// A copy that has finished is the moment a card is most likely to be pulled
    /// early, so the state that describes it has to keep saying so.
    @Test("In-progress states keep telling the user not to remove the card")
    func inProgressStatesWarnAboutTheCard() {
        for state in [PrincipalUIState.copying, .copyCompleteVerificationPending, .verifying] {
            let presentation = StatusPresentation.for(state)
            #expect(presentation.title.localizedCaseInsensitiveContains("do not remove card"))
            #expect(presentation.announcement.localizedCaseInsensitiveContains("do not remove the card"))
        }
    }

    @Test("A finished copy is never presented as a finished transfer")
    func copyCompleteIsNotSuccess() {
        let presentation = StatusPresentation.for(.copyCompleteVerificationPending)
        #expect(presentation.tone == .inProgress)
        #expect(presentation.tone != .success)
        #expect(presentation.detail.localizedCaseInsensitiveContains("not a finished transfer"))
    }

    /// Only a run where every destination verified may read as success.
    @Test("Only fully verified states carry the success tone")
    func successToneIsEarned() {
        let successes = PrincipalUIState.allCases.filter { StatusPresentation.for($0).tone == .success }
        #expect(Set(successes) == Set([.verified, .safeToEject, .ejected]))
        #expect(StatusPresentation.for(.primaryVerifiedBackupIncomplete).tone == .attention)
    }

    @Test("The paused status counts the files it is waiting on")
    func conflictCountIsSpoken() {
        #expect(StatusPresentation.for(.conflictPaused, conflictCount: 1).title.contains("1 file needs"))
        #expect(StatusPresentation.for(.conflictPaused, conflictCount: 4).title.contains("4 files need"))
        #expect(StatusPresentation.for(.conflictPaused, conflictCount: 4).announcement.contains("4 files"))
    }

    @Test("The combined accessibility label reads as one sentence")
    func accessibilityLabelCombinesTitleAndDetail() {
        let presentation = StatusPresentation.for(.verified)
        #expect(presentation.accessibilityLabel == "\(presentation.title). \(presentation.detail)")
    }
}

@Suite("Principal UI state fixtures")
struct UIStateFixtureTests {

    /// The gallery captures one screenshot per case. A state added without a
    /// fixture would silently drop out of the reference set.
    @Test("Every principal state has a fixture")
    func everyStateHasAFixture() {
        #expect(UIStateFixture.all.count == PrincipalUIState.allCases.count)
        #expect(Set(UIStateFixture.all.map(\.state)) == Set(PrincipalUIState.allCases))
        for fixture in UIStateFixture.all {
            #expect(fixture.presentation.state == fixture.state)
        }
    }

    /// Ejecting ends the transfer the screen was describing. Anything still
    /// shown would describe a card that is no longer mounted.
    @Test("The ejected fixture keeps the destinations and nothing about the card")
    func ejectedFixtureIsCleared() {
        let ejected = UIStateFixture.fixture(for: .ejected)
        #expect(ejected.sourceVolume == nil)
        #expect(ejected.sourcePath == nil)
        #expect(ejected.scan == nil)
        #expect(ejected.preflight == nil)
        #expect(ejected.copyProgress == nil)
        #expect(ejected.verificationProgress == nil)
        #expect(ejected.outcome == nil)
        #expect(ejected.detectedVolumes.isEmpty)
        #expect(!ejected.isWorking)
        // The destinations are the user's standing choice, not the finished
        // transfer's, so they survive the card leaving.
        #expect(ejected.destinationName != nil)
        #expect(ejected.backupName != nil)
    }

    @Test("Fixtures are deterministic, so two captures differ only if the UI did")
    func fixturesAreDeterministic() {
        let first = UIStateFixture.fixture(for: .copying)
        let second = UIStateFixture.fixture(for: .copying)
        #expect(first.copyProgress == second.copyProgress)
        #expect(first.scan?.totalBytes == second.scan?.totalBytes)
        #expect(first.transferName == second.transferName)
    }

    @Test("The copying fixture is mid-copy and the verifying fixture is mid-verification")
    func progressFixturesAreInTheirPhase() {
        let copying = UIStateFixture.fixture(for: .copying)
        #expect(copying.copyProgress?.phase == .copying)
        #expect(copying.copyProgress?.isPhaseComplete == false)
        #expect(copying.verificationProgress == nil)

        let pending = UIStateFixture.fixture(for: .copyCompleteVerificationPending)
        #expect(pending.copyProgress?.isPhaseComplete == true)
        // The transfer is not finished, so no outcome exists to render as one.
        #expect(pending.outcome == nil)

        let verifying = UIStateFixture.fixture(for: .verifying)
        #expect(verifying.verificationProgress?.phase == .verifying)
        #expect(verifying.verificationProgress?.isPhaseComplete == false)
    }

    @Test("The backup-incomplete fixture keeps both destination results")
    func partialOutcomeKeepsBothResults() throws {
        let outcome = try #require(UIStateFixture.fixture(for: .primaryVerifiedBackupIncomplete).outcome)
        #expect(outcome.state != .verified)
        #expect(outcome.destinations.count == 2)
        #expect(outcome.destinations.filter(\.isVerified).count == 1)
        let backup = try #require(outcome.destinations.first { !$0.isVerified })
        #expect(backup.failedFiles > 0)
        // A destination that did not verify has no final location to offer.
        #expect(backup.finalURL == nil)
    }

    @Test("The paused fixture is waiting on files, not reporting a result")
    func conflictFixturePauses() throws {
        let outcome = try #require(UIStateFixture.fixture(for: .conflictPaused).outcome)
        #expect(outcome.requiresConflictResolution)
        #expect(outcome.conflicts.allSatisfy { $0.classification.requiresAttention })
        #expect(outcome.conflicts.allSatisfy { !$0.explanation.isEmpty })
    }

    @Test("The interrupted fixture is an unfinished transfer that can be resumed")
    func interruptedFixtureIsResumable() throws {
        let scan = try #require(UIStateFixture.fixture(for: .interrupted).recovery)
        #expect(!scan.isEmpty)
        let transfer = try #require(scan.transfers.first)
        #expect(transfer.lastDurableState == .copying)
        #expect(transfer.verifiedFiles > 0)
        #expect(transfer.remainingFiles > 0)
        // One drive is away: the state has to be able to show that too.
        #expect(transfer.destinations.contains { !$0.isAvailable })
    }

    @Test("The no-source fixture really has no source, and the empty one really scanned")
    func emptyStatesAreEmpty() {
        let noSource = UIStateFixture.fixture(for: .noSource)
        #expect(noSource.sourceVolume == nil)
        #expect(noSource.scan == nil)
        #expect(noSource.detectedVolumes.isEmpty)

        let detected = UIStateFixture.fixture(for: .sourceDetected)
        #expect(detected.sourceVolume == nil)
        #expect(detected.detectedVolumes.contains { $0.identity.isRemovable })

        let empty = UIStateFixture.fixture(for: .noTransferableFiles)
        #expect(empty.scan?.files.isEmpty == true)
        #expect(empty.scan?.excludedFiles.isEmpty == false)
    }

    @Test("The blocked fixture cannot proceed and the warning fixture can")
    func preflightFixturesMatchTheirState() throws {
        let blocked = try #require(UIStateFixture.fixture(for: .preflightBlocked).preflight)
        #expect(!blocked.canProceed)
        #expect(blocked.issues.contains { $0.severity == .blocking })

        let warning = try #require(UIStateFixture.fixture(for: .preflightWarning).preflight)
        #expect(warning.canProceed)
        #expect(!warning.issues.isEmpty)
        #expect(warning.issues.allSatisfy { $0.severity == .warning })

        let ready = try #require(UIStateFixture.fixture(for: .ready).preflight)
        #expect(ready.canProceed)
        #expect(ready.issues.isEmpty)
    }
}
