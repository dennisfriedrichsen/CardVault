import Foundation
import Testing
@testable import CardVaultCore

/// Every archived file should sort by when it was shot, not by when it was
/// imported. These tests hold that promise from both ends: the dates really
/// land on the destination copies, and failing to write one never costs the
/// user a verified copy.
@Suite("Source timestamps on destination copies")
struct TimestampTests {

    // MARK: - The promise

    @Test("A verified copy carries the source's modification date")
    func modificationDateIsCarried() async throws {
        try await withTimestampFixture { fixture in
            let outcome = try await TransferCoordinator().execute(plan: fixture.plan)
            #expect(outcome.state == .verified)

            for name in fixture.fileNames {
                let source = try fixture.dates(of: fixture.sourceURL(name))
                let copy = try fixture.dates(of: fixture.finalURL(name))
                #expect(copy.modification == source.modification)
            }
        }
    }

    @Test("The creation date is carried too, where the destination stores one")
    func creationDateIsCarried() async throws {
        try await withTimestampFixture { fixture in
            // A temporary directory is APFS, which does store birth times.
            #expect(await LocalFileSystem().supportsCreationDates(in: fixture.destinationRoot))

            _ = try await TransferCoordinator().execute(plan: fixture.plan)

            let source = try fixture.dates(of: fixture.sourceURL("first.CR3"))
            let copy = try fixture.dates(of: fixture.finalURL("first.CR3"))
            #expect(copy.creation == source.creation)
            let result = try await fixture.result("first.CR3")
            #expect(result.timestamps?.creationDate == .applied)
            #expect(result.timestamps?.modificationDate == .applied)
        }
    }

    @Test("A destination that stores no creation date is recorded, not warned about")
    func unsupportedCreationDateIsQuiet() async throws {
        try await withTimestampFixture { fixture in
            // Stands in for NFS, which accepts the write and keeps a zero birth
            // time: what matters is that the fact is established once, for the
            // destination, rather than once per file.
            let outcome = try await LocalFileSystem().applyTimestamps(
                to: fixture.sourceURL("first.CR3"),
                creationDate: fixture.shootDate, modificationDate: fixture.shootDate,
                creationDatesSupported: false, tolerance: TimestampTolerance.exact)

            #expect(outcome.creationDate == .unsupported)
            #expect(outcome.modificationDate == .applied)
            #expect(!outcome.hasFailure)
        }
    }

    @Test("A source with no recorded date produces no shortfall")
    func missingSourceDateIsNotAShortfall() async throws {
        try await withTimestampFixture { fixture in
            let outcome = try await LocalFileSystem().applyTimestamps(
                to: fixture.sourceURL("first.CR3"), creationDate: nil, modificationDate: nil,
                creationDatesSupported: true, tolerance: TimestampTolerance.exact)

            #expect(outcome.creationDate == .unrecorded)
            #expect(outcome.modificationDate == .unrecorded)
            #expect(!outcome.hasFailure)
        }
    }

    // MARK: - A date is never allowed to cost a verified copy

    @Test("A copy whose dates cannot be written is still verified, and says so once")
    func failedTimestampNeverFailsTheCopy() async throws {
        try await withTimestampFixture { fixture in
            // Only the destination copy's attribute write is faulted: the source
            // path never contains the staging tree's Originals component.
            let injector = FaultInjector(rules: [
                .init(.attributes, pathContains: "Originals/DCIM/second.CR3", effect: .fail(.permissionDenied))
            ])

            let outcome = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector))
                .execute(plan: fixture.plan)

            // The bytes are the product. A date is not content.
            #expect(outcome.state == .verified)
            #expect(outcome.destinations[0].failedFiles == 0)
            let result = try await fixture.result("second.CR3")
            #expect(result.verification == .verified)
            #expect(result.timestamps?.hasFailure == true)
            #expect(result.timestamps?.error?.contains("permissionDenied") == true)

            let manifest = try await fixture.finalManifest()
            let notes = manifest.warnings.filter { $0.contains("kept the copy date") }
            #expect(notes.count == 1)
            #expect(notes[0].contains("Primary"))
            #expect(notes[0].contains("1 verified file"))
            // The file that could take its date still has it.
            let source = try fixture.dates(of: fixture.sourceURL("first.CR3"))
            #expect(try fixture.dates(of: fixture.finalURL("first.CR3")).modification == source.modification)
        }
    }

    // MARK: - Resume

    @Test("A resumed transfer dates the files an earlier run copied")
    func resumeAppliesDatesToEarlierWork() async throws {
        try await withTimestampFixture { fixture in
            // Leave a staging tree behind the way an interrupted run does.
            let injector = FaultInjector(rules: [
                .init(.write, pathContains: "third.jpg", effect: .fail(.disconnected))
            ])
            let stopped = try await TransferCoordinator(fileSystem: LocalFileSystem(injector: injector))
                .execute(plan: fixture.plan)
            #expect(stopped.state == .failed)

            // Rewind first.CR3 to the state a run that predates timestamping
            // left: verified bytes, and today's date on the file.
            let staged = fixture.stagedURL("first.CR3")
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: staged.path)
            var manifest = try await ManifestStore().load(from: fixture.stagingManifestURL)
            manifest.files[0].destinations[fixture.destinationID]?.timestamps = nil
            try await ManifestStore().save(manifest, to: fixture.stagingManifestURL)

            let outcome = try await TransferCoordinator().resume(plan: fixture.plan,
                                                                 manifestURL: fixture.stagingManifestURL)

            #expect(outcome.state == .verified)
            let source = try fixture.dates(of: fixture.sourceURL("first.CR3"))
            #expect(try fixture.dates(of: fixture.finalURL("first.CR3")).modification == source.modification)
            #expect(try await fixture.result("first.CR3").timestamps?.modificationDate == .applied)
        }
    }

    // MARK: - Granularity

    @Test("FAT-family destinations are given their two-second granularity as slack")
    func fatGranularityIsAllowed() {
        for name in ["exFAT", "MS-DOS FAT32", "msdos", "FAT"] {
            #expect(TimestampTolerance.forFileSystem(name) == TimestampTolerance.fatGranularity)
        }
        for name in ["APFS", "HFS+", "NFS", "SMB"] {
            #expect(TimestampTolerance.forFileSystem(name) == TimestampTolerance.exact)
        }
    }

    @Test("A sub-second modification time survives the round trip on APFS")
    func subSecondTimeIsPreserved() async throws {
        try await withTimestampFixture { fixture in
            // The precision ceiling is set by the card, not by CardVault: a FAT
            // card hands over whole even seconds, an exFAT one does not, and
            // whatever arrives has to reach the destination unrounded.
            let precise = Date(timeIntervalSince1970: 1_700_000_001.25)
            let outcome = try await LocalFileSystem().applyTimestamps(
                to: fixture.sourceURL("first.CR3"), creationDate: nil, modificationDate: precise,
                creationDatesSupported: false, tolerance: TimestampTolerance.exact)

            #expect(outcome.modificationDate == .applied)
            #expect(try fixture.dates(of: fixture.sourceURL("first.CR3")).modification == precise)
        }
    }

    // MARK: - Schema

    @Test("A manifest written before timestamps were recorded still decodes")
    func olderManifestStillDecodes() throws {
        let json = """
        {
          "copyState": "copied",
          "verification": "verified",
          "destinationChecksum": "abc"
        }
        """
        let result = try JSONDecoder().decode(DestinationFileResult.self, from: Data(json.utf8))
        #expect(result.verification == .verified)
        #expect(result.timestamps == nil)
        // Nothing recorded means nothing attempted, so a resume tries again.
        #expect(TimestampOutcome().needsApplication)
    }
}

// MARK: - Fixture

private struct TimestampFixture {
    let root: URL
    let source: URL
    let destinationRoot: URL
    let plan: TransferPlan
    let fileNames: [String]
    let shootDate: Date

    var destinationID: UUID { plan.destinations[0].id }
    var layout: TransferLayout { TransferLayout(plan: plan) }
    var stagingManifestURL: URL {
        TransferLayout.manifestURL(inStaging: layout.stagingRoot(in: destinationRoot))
    }

    func sourceURL(_ name: String) -> URL { source.appending(path: "DCIM/\(name)") }

    func stagedURL(_ name: String) -> URL {
        TransferLayout.originalsRoot(inStaging: layout.stagingRoot(in: destinationRoot))
            .appending(path: "DCIM/\(name)")
    }

    /// Wherever the copy is now: staging until finalisation renames the tree.
    func finalURL(_ name: String) -> URL {
        let final = TransferLayout.originalsRoot(inStaging: layout.finalRoot(in: destinationRoot))
            .appending(path: "DCIM/\(name)")
        return FileManager.default.fileExists(atPath: final.path) ? final : stagedURL(name)
    }

    func dates(of url: URL) throws -> (creation: Date?, modification: Date?) {
        let values = try URL(filePath: url.path)
            .resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (values.creationDate, values.contentModificationDate)
    }

    func finalManifest() async throws -> TransferManifest {
        let final = TransferLayout.manifestURL(inStaging: layout.finalRoot(in: destinationRoot))
        let url = FileManager.default.fileExists(atPath: final.path) ? final : stagingManifestURL
        return try await ManifestStore().load(from: url)
    }

    func result(_ name: String) async throws -> DestinationFileResult {
        let manifest = try await finalManifest()
        let file = manifest.files.first { $0.relativeSourcePath.hasSuffix(name) } ?? manifest.files[0]
        return file.destinations[destinationID] ?? DestinationFileResult()
    }
}

private func withTimestampFixture(_ body: (TimestampFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CardVaultTimestampTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appending(path: "CARD")
    try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
    let names = ["first.CR3", "second.CR3", "third.jpg"]
    // Dates far enough in the past that a copy carrying today's date instead is
    // unmistakable, and distinct per file so an assertion cannot pass by
    // accidentally reading the neighbour.
    let shootDate = Date(timeIntervalSince1970: 1_422_800_000)
    for (index, name) in names.enumerated() {
        let url = source.appending(path: "DCIM/\(name)")
        try Data(repeating: UInt8(index + 1), count: 40_000).write(to: url)
        let taken = shootDate.addingTimeInterval(Double(index) * 37)
        try FileManager.default.setAttributes([.creationDate: taken, .modificationDate: taken],
                                              ofItemAtPath: url.path)
    }

    let destinationRoot = root.appending(path: "destination")
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let destination = DestinationPlan(label: "Primary", rootPath: destinationRoot.path,
                                      volume: VolumeIdentity(displayName: "Archive", fileSystem: "APFS",
                                                             physicalStoreIdentifier: "disk0"))
    let files = try SourceScanner().scan(root: source, mode: .preserveCard).files
    let plan = TransferPlan(name: "Timestamp Transfer", mode: .preserveCard, sourceRootPath: source.path,
                            sourceVolume: VolumeIdentity(displayName: "CARD", fileSystem: "exFAT",
                                                         isRemovable: true, physicalStoreIdentifier: "source"),
                            files: files, destinations: [destination])
    try await body(TimestampFixture(root: root, source: source, destinationRoot: destinationRoot,
                                    plan: plan, fileNames: names, shootDate: shootDate))
}
