import Foundation
import Testing
@testable import CardVaultCore

@Suite("Transfer history detail, availability, and manifest authority")
struct HistoryTests {

    // MARK: - Encoding

    @Test("An entry round-trips with per-destination results intact")
    func entryRoundTrips() async throws {
        try await withFixture(destinationCount: 2) { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                manifest.state = .partiallySuccessful
                manifest.warnings = ["Backup drive was slower than expected."]
                for index in manifest.files.indices {
                    manifest.files[index].destinations[destinations[0]] =
                        DestinationFileResult(copyState: .copied, verification: .verified)
                }
                // The backup verified one file and mismatched the other, which is
                // exactly the case a single boolean would erase.
                manifest.files[0].destinations[destinations[1]] =
                    DestinationFileResult(copyState: .copied, verification: .verified)
                manifest.files[1].destinations[destinations[1]] =
                    DestinationFileResult(copyState: .copied, verification: .mismatch)
            }
            let entry = fixture.entry(from: manifest)
            let decoded = try #require(try JSONDecoder.history.decode(
                [TransferHistoryEntry].self, from: fixture.encode([entry])).first)

            #expect(decoded.id == entry.id)
            // ISO-8601 is written to the second, which is all a history index needs.
            #expect(abs(decoded.date.timeIntervalSince(entry.date)) < 1)
            #expect(decoded.name == manifest.transferName)
            #expect(decoded.finalState == .partiallySuccessful)
            #expect(decoded.warnings == manifest.warnings)
            #expect(decoded.results.count == 2)

            let primary = try #require(decoded.result(for: manifest.destinations[0].id))
            #expect(primary.isFullyVerified)
            #expect(primary.verifiedFiles == manifest.files.count)

            let backup = try #require(decoded.result(for: manifest.destinations[1].id))
            #expect(!backup.isFullyVerified)
            #expect(backup.verifiedFiles == 1)
            #expect(backup.mismatchedFiles == 1)
            #expect(backup.unverifiedFiles == 1)

            #expect(!decoded.isFullyVerified)
            #expect(decoded.verifiedDestinationIDs == [manifest.destinations[0].id])
        }
    }

    @Test("A stored index is read back after a relaunch")
    func indexSurvivesRelaunch() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let url = fixture.root.appending(path: "transfer-history.json")
            try await TransferHistoryStore(url: url).add(fixture.entry(from: manifest))

            // Dates are written as ISO-8601, so they have to be read as ISO-8601.
            // A decoder that disagrees drops the whole index without a word.
            let reloaded = await TransferHistoryStore(url: url).all()
            #expect(reloaded.count == 1)
            #expect(reloaded.first?.id == manifest.transferID)
            #expect(reloaded.first?.isFullyVerified == true)
        }
    }

    @Test("An index written before per-destination results still decodes")
    func decodesLegacyIndex() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let destinationID = manifest.destinations[0].id
            let legacy: [String: Any] = [
                "id": manifest.transferID.uuidString,
                "name": manifest.transferName,
                "date": ISO8601DateFormatter().string(from: manifest.createdAt),
                "source": ["displayName": "CARD", "fileSystem": "exFAT",
                           "isRemovable": true, "isLocal": true],
                "destinations": [["id": destinationID.uuidString, "label": "Primary",
                                  "volume": ["displayName": "Archive", "fileSystem": "APFS",
                                             "isRemovable": false, "isLocal": true]]],
                "totalFiles": manifest.files.count,
                "totalBytes": 2048,
                "mode": TransferMode.preserveCard.rawValue,
                "finalState": TransferState.verified.rawValue,
                "warnings": [],
                "verifiedDestinationIDs": [destinationID.uuidString],
                "manifestPaths": [fixture.manifestURL().path]
            ]
            let data = try JSONSerialization.data(withJSONObject: [legacy])
            let decoded = try #require(try JSONDecoder.history.decode([TransferHistoryEntry].self, from: data).first)

            let result = try #require(decoded.result(for: destinationID))
            #expect(result.isFullyVerified)
            #expect(result.totalFiles == manifest.files.count)
            #expect(result.manifestPath == fixture.manifestURL().path)
            #expect(decoded.manifestPaths == [fixture.manifestURL().path])
        }
    }

    @Test("The index records no destination paths beyond the manifest locations")
    func indexKeepsPathsOutOfTheRecord() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let json = try #require(String(data: fixture.encode([fixture.entry(from: manifest)]), encoding: .utf8))
            // The destination root reaches disk only as the manifest location the
            // index needs to reopen; the plan's own rootPath is never written.
            #expect(!json.contains("\"rootPath\""))
            #expect(json.contains(TransferLayout.manifestRelativePath))

            let portable = try #require(String(data: try Data(contentsOf: fixture.manifestURL()), encoding: .utf8))
            #expect(!portable.contains(fixture.destinationRoots[0].path))
            #expect(!portable.contains("bookmark"))
        }
    }

    // MARK: - Replacement

    @Test("Re-recording a transfer replaces its entry instead of duplicating it")
    func addReplacesEntry() async throws {
        try await withFixture { fixture in
            let url = fixture.root.appending(path: "transfer-history.json")
            let store = TransferHistoryStore(url: url)
            let interrupted = try await fixture.writeManifest { manifest, _ in
                manifest.state = .interrupted
            }
            try await store.add(fixture.entry(from: interrupted))

            var finished = interrupted
            finished.state = .verified
            fixture.verifyEverything(&finished, at: finished.destinations.map(\.id))
            try await store.add(fixture.entry(from: finished))

            let all = await store.all()
            #expect(all.count == 1)
            #expect(all.first?.finalState == .verified)
            #expect(all.first?.isFullyVerified == true)
        }
    }

    @Test("An entry rebuilt from the manifest replaces a stale indexed copy")
    func mergeReplacesStaleEntry() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let url = fixture.root.appending(path: "transfer-history.json")
            let store = TransferHistoryStore(url: url)
            var stale = manifest
            stale.state = .interrupted
            stale.files = Array(manifest.files.prefix(1))
            try await store.add(fixture.entry(from: stale))

            let rebuilt = await fixture.inspector().rebuildEntries(fromDestinationRoots: fixture.destinationRoots)
            #expect(rebuilt.count == 1)
            _ = try await store.merge(rebuilt)

            let all = await store.all()
            #expect(all.count == 1)
            #expect(all.first?.finalState == .verified)
            #expect(all.first?.totalFiles == manifest.files.count)
            // A wiped index costs nothing: the drives carry the record.
            let fresh = TransferHistoryStore(url: fixture.root.appending(path: "empty-history.json"))
            _ = try await fresh.merge(rebuilt)
            #expect(await fresh.all().first?.id == manifest.transferID)
        }
    }

    // MARK: - Destination availability

    @Test("A connected destination is available and can be revealed and inspected")
    func availableDestination() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let status = try #require(await fixture.inspector()
                .availability(for: fixture.entry(from: manifest)).first)
            #expect(status.availability == .available)
            #expect(status.canReveal)
            #expect(status.canOpenManifest)
            #expect(status.revealUnavailableReason == nil)
            #expect(status.transferRoot == fixture.transferRoot())
            #expect(status.isVerified)
        }
    }

    @Test("A disconnected drive is reported as missing without unverifying the transfer")
    func missingDriveKeepsVerification() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let entry = fixture.entry(from: manifest)
            // The drive goes away; the record of what it holds does not.
            try FileManager.default.removeItem(at: fixture.destinationRoots[0])

            let detail = await fixture.inspector().detail(for: entry)
            let status = try #require(detail.destinations.first)
            #expect(status.availability == .missing)
            #expect(status.isVerified)
            #expect(status.result?.verifiedFiles == manifest.files.count)
            #expect(status.verificationSummary.contains("verified"))
            #expect(!status.canReveal)
            #expect(!status.canOpenManifest)
            #expect(status.revealUnavailableReason?.contains("not connected") == true)
            #expect(detail.availableDestinations.isEmpty)
            #expect(detail.missingDestinations.count == 1)
            // The index is still shown, and said to be only an index.
            #expect(detail.manifest == nil)
            #expect(detail.authorityNote?.contains("authoritative") == true)
            #expect(entry.isFullyVerified)
        }
    }

    @Test("A different volume at the same path is not the recorded destination")
    func mismatchedVolume() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            // Same mount path, different drive: the label is not the test.
            let inspector = fixture.inspector(overriding: [fixture.transferRoot().path: UUID()])
            let status = try #require(await inspector.availability(for: fixture.entry(from: manifest)).first)
            #expect(status.availability == .mismatched)
            #expect(!status.canReveal)
            #expect(!status.canOpenManifest)
            #expect(status.revealUnavailableReason?.contains(manifest.destinations[0].volume.displayName) == true)
        }
    }

    @Test("A volume that cannot identify itself is reported as unconfirmed, not refused")
    func indeterminateVolume() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            var anonymous = manifest
            anonymous.destinations[0] = DestinationPlan(
                id: manifest.destinations[0].id, label: "Primary",
                rootPath: fixture.destinationRoots[0].path,
                volume: VolumeIdentity(displayName: "Archive", fileSystem: "APFS"))
            let inspector = fixture.inspector(overriding: [fixture.transferRoot().path: nil])
            let status = try #require(await inspector.availability(for: fixture.entry(from: anonymous)).first)
            #expect(status.availability == .indeterminate)
            #expect(status.canReveal)
            #expect(status.canOpenManifest)
        }
    }

    @Test("Availability is reported for each destination independently")
    func perDestinationAvailability() async throws {
        try await withFixture(destinationCount: 2) { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            try FileManager.default.removeItem(at: fixture.destinationRoots[1])
            let statuses = await fixture.inspector().availability(for: fixture.entry(from: manifest))
            #expect(statuses.map(\.availability) == [.available, .missing])
            #expect(statuses.allSatisfy { $0.isVerified })
        }
    }

    // MARK: - Manifest authority

    @Test("The manifest is named as authoritative when the index disagrees with it")
    func manifestWinsOverIndex() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            // An index entry that claims more than the manifest supports.
            var overstated = manifest
            overstated.transferName = "Renamed In The Index"
            overstated.state = .verified
            overstated.files = Array(manifest.files.prefix(1))
            let entry = fixture.entry(from: overstated)

            let detail = await fixture.inspector().detail(for: entry)
            #expect(detail.manifest?.transferID == manifest.transferID)
            #expect(detail.manifestURL == fixture.manifestURL())
            #expect(!detail.indexAgreesWithManifest)
            #expect(detail.authorityNote?.contains("manifest on the destination is authoritative") == true)
            let fields = Set(detail.discrepancies.map(\.field))
            #expect(fields.contains("Transfer name"))
            #expect(fields.contains("Files"))
            let files = try #require(detail.discrepancies.first { $0.field == "Files" })
            #expect(files.manifestValue == "\(manifest.files.count)")
        }
    }

    @Test("An agreeing index is presented without a correction")
    func agreeingIndexIsQuiet() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let detail = await fixture.inspector().detail(for: fixture.entry(from: manifest))
            #expect(detail.discrepancies.isEmpty)
            #expect(detail.indexAgreesWithManifest)
            #expect(detail.authorityNote == nil)
        }
    }

    @Test("A manifest this build cannot read is reported rather than guessed at")
    func unreadableManifestIsReported() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let entry = fixture.entry(from: manifest)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL()))
                as? [String: Any])
            json["schemaVersion"] = TransferManifest.currentSchemaVersion + 1
            try JSONSerialization.data(withJSONObject: json).write(to: fixture.manifestURL())

            let detail = await fixture.inspector().detail(for: entry)
            #expect(detail.manifest == nil)
            #expect(detail.manifestUnavailableReason?.contains("schema version") == true)
            #expect(detail.authorityNote?.contains("authoritative") == true)
            // The destination is still there and still openable for inspection.
            #expect(detail.destinations.first?.canOpenManifest == true)
        }
    }

    @Test("History records a real transfer at the location the manifest was written")
    func recordsCompletedTransfer() async throws {
        try await withFixture { fixture in
            let outcome = try await TransferCoordinator().execute(plan: fixture.plan)
            #expect(outcome.state == .verified)
            let finalURL = try #require(outcome.destinations.first?.finalURL)
            let manifestURL = TransferLayout.manifestURL(inStaging: finalURL)
            let manifest = try await ManifestStore().load(from: manifestURL)
            let entry = TransferHistoryEntry(manifest: manifest,
                                             manifestPaths: [fixture.plan.destinations[0].id: manifestURL.path])
            #expect(entry.isFullyVerified)

            let detail = await fixture.inspector().detail(for: entry)
            #expect(detail.indexAgreesWithManifest)
            #expect(detail.destinations.first?.availability == .available)
            #expect(detail.destinations.first?.canOpenManifest == true)
        }
    }

    // MARK: - Companion app handoff

    @Test("A verified, connected destination can be handed to the companion app")
    func handoffIsOfferedWhenVerified() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let status = try #require(await fixture.inspector()
                .availability(for: fixture.entry(from: manifest)).first)
            let installed = URL(filePath: "/Applications/SDelight.app")
            let handoff = ExternalAppHandoff(locator: StubLocator(installed: [
                HandoffTarget.sdelight.bundleIdentifiers[0]: installed]))
            let availability = handoff.availability(for: status)
            #expect(availability.isReady)
            #expect(availability.applicationURL == installed)
            #expect(availability.explanation == nil)
        }
    }

    @Test("Handoff is explained rather than silently unavailable")
    func handoffExplainsWhyItIsUnavailable() async throws {
        try await withFixture { fixture in
            let manifest = try await fixture.writeManifest { manifest, destinations in
                // Verified everywhere but one file, which is not verified enough.
                fixture.verifyEverything(&manifest, at: destinations)
                manifest.files[0].destinations[destinations[0]] =
                    DestinationFileResult(copyState: .copied, verification: .pending)
            }
            let entry = fixture.entry(from: manifest)
            let status = try #require(await fixture.inspector().availability(for: entry).first)
            let installed = [HandoffTarget.sdelight.bundleIdentifiers[0]: URL(filePath: "/Applications/SDelight.app")]

            let unverified = ExternalAppHandoff(locator: StubLocator(installed: installed)).availability(for: status)
            #expect(!unverified.isReady)
            #expect(unverified.explanation?.contains("not fully verified") == true)

            // Verified, connected, but the app is not installed.
            let verified = try await fixture.writeManifest { manifest, destinations in
                fixture.verifyEverything(&manifest, at: destinations)
            }
            let ready = try #require(await fixture.inspector()
                .availability(for: fixture.entry(from: verified)).first)
            let missingApp = ExternalAppHandoff(locator: StubLocator(installed: [:])).availability(for: ready)
            #expect(!missingApp.isReady)
            #expect(missingApp.explanation?.contains("not installed") == true)

            // Verified, app installed, drive away.
            try FileManager.default.removeItem(at: fixture.destinationRoots[0])
            let away = try #require(await fixture.inspector()
                .availability(for: fixture.entry(from: verified)).first)
            let disconnected = ExternalAppHandoff(locator: StubLocator(installed: installed)).availability(for: away)
            #expect(!disconnected.isReady)
            #expect(disconnected.explanation?.contains("connected") == true)
        }
    }
}

// MARK: - Fixture

private struct StubLocator: ExternalApplicationLocator {
    let installed: [String: URL]
    func applicationURL(forBundleIdentifier identifier: String) -> URL? { installed[identifier] }
}

private struct HistoryFixture {
    let root: URL
    let source: URL
    let destinationRoots: [URL]
    let plan: TransferPlan
    /// Volume UUID each path resolves to, so "same drive elsewhere" and
    /// "different drive, same name" are expressible without mounting anything.
    let volumeUUIDs: [String: UUID]

    var layout: TransferLayout { TransferLayout(plan: plan) }

    func transferRoot(_ index: Int = 0) -> URL { layout.finalRoot(in: destinationRoots[index]) }
    func manifestURL(_ index: Int = 0) -> URL { TransferLayout.manifestURL(inStaging: transferRoot(index)) }

    /// `overriding` replaces what the resolver reports for a path: a new UUID is
    /// a different drive, an explicit nil is a drive that cannot identify itself.
    func inspector(overriding overrides: [String: UUID?] = [:]) -> TransferHistoryInspector {
        let table = volumeUUIDs
        return TransferHistoryInspector(resolver: VolumeIdentityResolver(provider: nil, factsProvider: { url in
            let path = url.standardizedFileURL.path
            let uuid = overrides.keys.contains(path) ? overrides[path] ?? nil : table[path]
            return URLResourceVolumeFacts(volumeUUID: uuid, volumeName: url.lastPathComponent,
                                          fileSystem: "APFS", isLocal: true, isRemovable: false)
        }))
    }

    /// Writes a finished transfer's manifest where a completed transfer leaves
    /// one: inside the transfer's final folder on each destination.
    @discardableResult
    func writeManifest(_ configure: (inout TransferManifest, [UUID]) -> Void) async throws -> TransferManifest {
        var manifest = TransferManifest(plan: plan)
        manifest.state = .verified
        manifest.startedAt = Date()
        manifest.completedAt = Date()
        manifest.verifiedAt = Date()
        configure(&manifest, plan.destinations.map(\.id))
        for index in destinationRoots.indices {
            try await ManifestStore().save(manifest, to: manifestURL(index))
        }
        return manifest
    }

    func verifyEverything(_ manifest: inout TransferManifest, at destinationIDs: [UUID]) {
        for index in manifest.files.indices {
            for destinationID in destinationIDs {
                manifest.files[index].destinations[destinationID] =
                    DestinationFileResult(copyState: .copied, verification: .verified)
            }
        }
    }

    func entry(from manifest: TransferManifest) -> TransferHistoryEntry {
        let paths = manifest.destinations.enumerated().reduce(into: [UUID: String]()) { paths, pair in
            guard pair.offset < destinationRoots.count else { return }
            paths[pair.element.id] = manifestURL(pair.offset).path
        }
        return TransferHistoryEntry(manifest: manifest, manifestPaths: paths)
    }

    func encode(_ entries: [TransferHistoryEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(entries)) ?? Data()
    }
}

private func withFixture(destinationCount: Int = 1,
                         _ body: (HistoryFixture) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CardVaultHistoryTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appending(path: "CARD")
    try FileManager.default.createDirectory(at: source.appending(path: "DCIM"), withIntermediateDirectories: true)
    for name in ["first.CR3", "second.jpg"] {
        try Data("contents of \(name) padded out a little".utf8)
            .write(to: source.appending(path: "DCIM/\(name)"))
    }

    let destinationRoots = (0..<destinationCount).map { root.appending(path: "destination-\($0)") }
    for url in destinationRoots { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    let sourceUUID = UUID()
    var volumeUUIDs: [String: UUID] = [source.standardizedFileURL.path: sourceUUID]
    let sourceVolume = VolumeIdentity(volumeUUID: sourceUUID, resourceIdentifier: sourceUUID.uuidString,
                                      displayName: "CARD", fileSystem: "exFAT", isRemovable: true)
    let plan = TransferPlan(
        name: "August Shoot", mode: .preserveCard, sourceRootPath: source.path, sourceVolume: sourceVolume,
        files: try SourceScanner().scan(root: source, mode: .preserveCard).files,
        destinations: destinationRoots.enumerated().map { index, url in
            let uuid = UUID()
            // A destination's identity has to resolve from the transfer folder
            // as well as from the drive root, which is where availability looks.
            volumeUUIDs[url.standardizedFileURL.path] = uuid
            volumeUUIDs[url.appending(path: "August Shoot").standardizedFileURL.path] = uuid
            return DestinationPlan(id: UUID(), label: index == 0 ? "Primary" : "Backup", rootPath: url.path,
                                   volume: VolumeIdentity(volumeUUID: uuid, resourceIdentifier: uuid.uuidString,
                                                          displayName: index == 0 ? "Archive" : "Backup Drive",
                                                          fileSystem: "APFS"))
        })
    try await body(HistoryFixture(root: root, source: source, destinationRoots: destinationRoots,
                                  plan: plan, volumeUUIDs: volumeUUIDs))
}
