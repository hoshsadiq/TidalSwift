//
//  TemporaryOfflineLibraryTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Guards the two properties that keep the rest of the suite off this machine's real account
/// and real music folder: a test session must not load the developer's stored token, and
/// `Offline.init` must not sync against `~/Music/TidalSwift Offline Library`.
@MainActor
final class TemporaryOfflineLibraryTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "IsolationGuard")

	/// The developer's real values, so a test snapshots and restores them around any call.
	private let sessionKeys = ["Config Information", "Session Information"]
	private let sentinelKey = "TidalSwiftTests:LogoutSentinel"

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	/// `Config.load()`, which `Session(config: nil)` calls, reads whatever is stored under
	/// "Config Information" — a real account token on a developer machine.
	func testSessionDoesNotUseAStoredAccount() {
		let session = offlineLibrary.makeSession()
		XCTAssertTrue(session.config.accessToken.isEmpty, "test session carries a stored access token")
		XCTAssertTrue(session.config.refreshToken.isEmpty, "test session carries a stored refresh token")
	}

	func testOfflineRootIsTemporary() {
		let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
		XCTAssertTrue(
			offlineLibrary.root.standardizedFileURL.path.hasPrefix(temporary),
			"offline root is outside the temporary directory: \(offlineLibrary.root.path)"
		)
	}

	/// A pinned track is not a favourite, an album or a playlist, so the wanted set must take it
	/// from the standalone set; otherwise the sync would delete its file on the next run.
	func testPinnedTrackStaysInTheSyncWantedSetWithoutBeingAFavourite() {
		let db = OfflineDB(defaults: offlineLibrary.defaults)
		let track = makeTrack(id: 987_654_321)

		db.addStandaloneOfflineTrack(track)

		XCTAssertFalse(db.favoriteTracks.contains(track), "the pinned track must not be a favourite for this test to mean anything")
		XCTAssertTrue(db.tracks.contains(track), "a pinned track must be part of the offline set even though it is not a favourite")
	}

	/// Unpinning a track no other source holds is what makes the sync delete its file.
	func testRemovingThePinMakesTheTrackEligibleForRemoval() {
		let db = OfflineDB(defaults: offlineLibrary.defaults)
		let track = makeTrack(id: 987_654_322)

		db.addStandaloneOfflineTrack(track)
		db.removeStandaloneOfflineTrack(track)

		XCTAssertFalse(db.tracks.contains(track), "an unpinned track held by no favourite, album or playlist must leave the offline set")
	}

	/// The pinned set is persisted (`OfflineDB` re-reads UserDefaults in `init`).
	func testPinnedTracksArePersistedAndReloaded() {
		let track = makeTrack(id: 987_654_323)

		OfflineDB(defaults: offlineLibrary.defaults).addStandaloneOfflineTrack(track)

		XCTAssertTrue(OfflineDB(defaults: offlineLibrary.defaults).tracks.contains(track), "a pinned track must be reloaded from the persisted set")
	}

	/// A lost date comes back from the file's own creation date, not from "now".
	func testFileOnDiskWithoutStoredDateBackfillsFromItsCreationDate() async throws {
		let trackId = 987_654_401
		let fileDate = Date(timeIntervalSince1970: 1_600_000_000)
		try createOfflineFile(forTrackId: trackId, createdAt: fileDate)
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }
		let started = await offline.awaitOngoingSync()
		XCTAssertTrue(started, "the launch sync must start")
		let added = try XCTUnwrap(offline.addedDate(forTrackId: trackId))
		XCTAssertEqual(added.timeIntervalSince1970, fileDate.timeIntervalSince1970, accuracy: 1,
					   "a date must come from the file on disk, not the current time")
	}

	/// Even though the file on disk carries a different creation date.
	func testExistingAddedDateSurvivesAReload() async throws {
		let trackId = 987_654_402
		let existingDate = Date(timeIntervalSince1970: 1_500_000_000)
		try createOfflineFile(forTrackId: trackId, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)], dates: [trackId: existingDate])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }
		let started = await offline.awaitOngoingSync()
		XCTAssertTrue(started, "the launch sync must start")
		let added = try XCTUnwrap(offline.addedDate(forTrackId: trackId))
		XCTAssertEqual(added.timeIntervalSince1970, existingDate.timeIntervalSince1970, accuracy: 1,
					   "an existing date must not be moved by a file that has a different creation date")
	}

	func testWantedTrackWithoutAFileStillGetsADate() async throws {
		let trackId = 987_654_403
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)])

		let before = Date()
		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }
		let started = await offline.awaitOngoingSync()
		XCTAssertTrue(started, "the launch sync must start")
		let added = try XCTUnwrap(offline.addedDate(forTrackId: trackId))
		XCTAssertGreaterThanOrEqual(added.timeIntervalSince(before), -1, "a track with no file must fall back to now")
		XCTAssertLessThanOrEqual(added.timeIntervalSince(before), 5)
	}

	func testBackfilledAddedDatesArePersisted() async throws {
		let trackId = 987_654_404
		let fileDate = Date(timeIntervalSince1970: 1_600_000_000)
		try createOfflineFile(forTrackId: trackId, createdAt: fileDate)
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }
		let started = await offline.awaitOngoingSync()
		XCTAssertTrue(started, "the launch sync must start")
		let inMemory = try XCTUnwrap(offline.addedDate(forTrackId: trackId))
		XCTAssertEqual(inMemory.timeIntervalSince1970, fileDate.timeIntervalSince1970, accuracy: 1)

		let reloaded = OfflineDB(defaults: offlineLibrary.defaults)
		let persisted = try XCTUnwrap(reloaded.trackAddedDates[trackId])
		XCTAssertEqual(persisted.timeIntervalSince1970, fileDate.timeIntervalSince1970, accuracy: 1,
					   "the backfilled date must be persisted, not just held in memory")
	}

	// MARK: - Logout

	/// The verifier's size floor and magic check are what keep the fixtures these tests store from
	/// being re-resolved: a fixture it stopped accepting would send every test that stores one to
	/// the live resolver. The resolver is stubbed here, so a threshold change is an assertion
	/// rather than a silent dial-out elsewhere.
	///
	/// Each branch is guarded by the smallest fixture the suite can ask it to verify. The FLAC
	/// fixture is sized from `minimumPlayableFileBytes` (`createOfflineFile`), so it protects by
	/// construction: a raised floor scales it and it still clears. The MP4 fixture is the fixed
	/// 588-byte `eac3-init.mp4` the Atmos tests store, the smallest one the suite uses, so this is
	/// the only assertion that states the fixture itself must clear the floor. It is not the only
	/// thing that catches a raised one: the other tests that store this fixture red as well.
	func testTheOfflineFixturesClearTheVerifier() async throws {
		let flacTrackId = 987_654_601
		let mp4TrackId = 987_654_602
		let libraryDirectory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		try createOfflineFile(forTrackId: flacTrackId, createdAt: Date(timeIntervalSince1970: 1_600_000_000))
		let smallestMP4 = try XCTUnwrap(Bundle.module.url(forResource: "eac3-init", withExtension: "mp4", subdirectory: "Fixtures"))
		try FileManager.default.copyItem(
			at: smallestMP4,
			to: libraryDirectory.appendingPathComponent("\(mp4TrackId).lossless.m4a")
		)

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		let resolves = Counter()
		offline.resolveOfflineStream = { _ in
			resolves.value += 1
			return nil
		}
		offline.setOfflineTracksForTesting([makeTrack(id: flacTrackId), makeTrack(id: mp4TrackId)])
		let started = await offline.awaitOngoingSync()
		XCTAssertTrue(started, "the sync must start, or this guard asserts nothing")

		XCTAssertEqual(
			resolves.value, 0,
			"the stored fixtures must be accepted by the verifier, or the tests that store one reach the live resolver"
		)
		XCTAssertTrue(fileExists(forTrackId: flacTrackId), "an accepted fixture must be kept, not re-resolved")
		XCTAssertTrue(
			HLSStreaming.isPlayableMP4File(at: smallestMP4),
			"the MP4 fixture itself must clear the floor, or every test that stores it reaches the live resolver"
		)
	}

	/// The keep path never calls `removeAll()`, so the file and its database entry both survive
	/// the sync.
	func testKeepingDownloadsLeavesFileAndDatabaseIntact() async throws {
		let trackId = 987_654_501
		let track = makeTrack(id: trackId)
		try createOfflineFile(forTrackId: trackId, createdAt: Date(timeIntervalSince1970: 1_600_000_000))
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [track])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		await offline.awaitOngoingSync()

		XCTAssertTrue(fileExists(forTrackId: trackId), "keeping downloads must not delete the downloaded file")
		XCTAssertTrue(OfflineDB(defaults: offlineLibrary.defaults).tracks.contains(track), "keeping downloads must not clear the database")
	}

	/// An empty wanted set is not a request to delete the library. If the database is
	/// lost or never loaded while files are on disk, the sync keeps them.
	func testEmptyDatabaseDoesNotRemoveDownloadedFiles() async throws {
		let trackId = 987_654_504
		try createOfflineFile(forTrackId: trackId, createdAt: Date(timeIntervalSince1970: 1_600_000_000))
		// No `persistOfflineState`: the database is empty, the disk is not.

		let session = offlineLibrary.makeSession()
		await session.helpers.offline.awaitOngoingSync()

		XCTAssertTrue(fileExists(forTrackId: trackId), "an empty database must not be read as 'remove everything'")
	}

	/// A stored payload that cannot be read is not a missing one: its tracks are still
	/// on disk, so an empty wanted set next to files means "the database did not load",
	/// not "nothing is wanted any more". The guard was written for this case but only
	/// ever exercised with no stored payload at all.
	func testUndecodableStoredStateDoesNotRemoveDownloadedFiles() async throws {
		let trackId = 987_654_505
		try createOfflineFile(forTrackId: trackId, createdAt: Date(timeIntervalSince1970: 1_600_000_000))
		offlineLibrary.defaults.set(Data("not a stored album list".utf8), forKey: "OfflineDB:Albums")

		let session = offlineLibrary.makeSession()
		await session.helpers.offline.awaitOngoingSync()

		XCTAssertTrue(fileExists(forTrackId: trackId), "a payload that failed to decode must not read as an empty offline list")
	}

	/// The half-read case: one section decodes while another does not. The sections
	/// that failed read as empty, so the tracks they hold look unwanted although their
	/// files are on disk and their payload was still there. The decoded section used to
	/// be enough to mark the whole database as ours, so the sync deleted those files.
	func testPartiallyReadableStoredStateKeepsTheFilesOfTheUnreadSection() async throws {
		let trackId = 987_654_506
		try createOfflineFile(forTrackId: trackId, createdAt: Date(timeIntervalSince1970: 1_600_000_000))
		offlineLibrary.defaults.set(try? JSONEncoder().encode([makeAlbum(id: 111)]), forKey: "OfflineDB:Albums")
		offlineLibrary.defaults.set(Data("not a stored favourite list".utf8), forKey: "OfflineDB:FavoriteTracks")

		let session = offlineLibrary.makeSession()
		await session.helpers.offline.awaitOngoingSync()

		XCTAssertTrue(fileExists(forTrackId: trackId), "a section that failed to decode must not be read as an empty one")
	}

	/// This is the destructive path the confirmation dialog offers, and it must delete the file
	/// and clear the database.
	func testRemovingDownloadsClearsFileAndDatabase() async throws {
		let trackId = 987_654_502
		let track = makeTrack(id: trackId)
		try createOfflineFile(forTrackId: trackId, createdAt: Date(timeIntervalSince1970: 1_600_000_000))
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [track])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		await offline.awaitOngoingSync()

		offline.removeAll()
		let cleared = await waitUntil {
			!self.fileExists(forTrackId: trackId) && !OfflineDB(defaults: self.offlineLibrary.defaults).tracks.contains(track)
		}

		XCTAssertTrue(cleared, "removing downloads must delete the file and clear the database")
	}

	/// A plain logout (keep downloads) must not touch the offline state: wiping the `OfflineDB:*`
	/// database would empty the library on the next launch's sync.
	func testLogoutKeepsOfflineDatabaseAndPreferences() {
		let track = makeTrack(id: 987_654_503)
		let offlineStore = offlineLibrary.defaults
		offlineStore.set(true, forKey: "SaveFavoritesOffline")
		offlineStore.set(true, forKey: "offlinePreferDolbyAtmos")
		OfflineDB(defaults: offlineStore).addStandaloneOfflineTrack(track) // persists OfflineDB:StandaloneOfflineTracks

		withPreservedDefaults(sessionKeys + [sentinelKey]) {
			UserDefaults.standard.set(["countryCode": "US", "userId": "1"], forKey: "Session Information")
			UserDefaults.standard.set("survives", forKey: sentinelKey)

			offlineLibrary.makeSession().logout()

			XCTAssertNil(UserDefaults.standard.object(forKey: "Session Information"),
						  "logout must clear the stored session")
			XCTAssertNil(UserDefaults.standard.object(forKey: "Config Information"),
						  "logout must clear the stored config")
			XCTAssertEqual(UserDefaults.standard.string(forKey: sentinelKey), "survives",
						   "logout owns the session keys, not the whole defaults domain")
			XCTAssertNotNil(offlineStore.data(forKey: "OfflineDB:StandaloneOfflineTracks"),
							"logout must leave the offline database alone")
			XCTAssertTrue(offlineStore.bool(forKey: "SaveFavoritesOffline"),
						  "logout must leave the offline preferences alone")
			XCTAssertTrue(offlineStore.bool(forKey: "offlinePreferDolbyAtmos"),
						  "logout must leave the offline preferences alone")
		}
	}

	/// Even called directly, `deletePersistentInformation` must not reach a single `OfflineDB:*`
	/// key or offline preference.
	func testDeletePersistentInformationCannotTouchOfflineState() {
		let track = makeTrack(id: 987_654_504)
		let offlineStore = offlineLibrary.defaults
		offlineStore.set(true, forKey: "offlinePreferDolbyAtmos")
		OfflineDB(defaults: offlineStore).addStandaloneOfflineTrack(track)

		withPreservedDefaults(sessionKeys + [sentinelKey]) {
			UserDefaults.standard.set(["countryCode": "US", "userId": "1"], forKey: "Session Information")
			UserDefaults.standard.set("survives", forKey: sentinelKey)

			offlineLibrary.makeSession().deletePersistentInformation()

			XCTAssertNil(UserDefaults.standard.object(forKey: "Session Information"))
			XCTAssertNil(UserDefaults.standard.object(forKey: "Config Information"))
			XCTAssertEqual(UserDefaults.standard.string(forKey: sentinelKey), "survives",
						   "deletePersistentInformation owns the session keys, not the whole defaults domain")
			XCTAssertNotNil(offlineStore.data(forKey: "OfflineDB:StandaloneOfflineTracks"),
							"deletePersistentInformation must not touch the offline database")
			XCTAssertTrue(offlineStore.bool(forKey: "offlinePreferDolbyAtmos"),
						  "deletePersistentInformation must not touch the offline preferences")
		}
	}

	// MARK: - Helpers

	private final class Counter {
		var value = 0
	}

	/// Snapshots and restores the given keys around a call, so a test running
	/// against the developer's real UserDefaults domain puts back exactly what it
	/// found.
	private func withPreservedDefaults(_ keys: [String], _ body: () -> Void) {
		let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
		defer {
			for (key, value) in saved {
				if let value {
					UserDefaults.standard.set(value, forKey: key)
				} else {
					UserDefaults.standard.removeObject(forKey: key)
				}
			}
		}
		body()
	}

	/// Bounded so a broken sync fails the test instead of hanging it.
	private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return true }
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		return condition()
	}

	private func fileExists(forTrackId trackId: Int) -> Bool {
		let file = offlineLibrary.root
			.appendingPathComponent("TidalSwift Offline Library")
			.appendingPathComponent("\(trackId).lossless.flac")
		return FileManager.default.fileExists(atPath: file.path)
	}

	/// Drives the load path, where dates are backfilled, without a Tidal account or the real
	/// library.
	private func persistOfflineState(album: Album, tracks: [Track], dates: [Int: Date] = [:]) {
		let encoder = JSONEncoder()
		offlineLibrary.defaults.set(try? encoder.encode([album]), forKey: "OfflineDB:Albums")
		offlineLibrary.defaults.set(try? encoder.encode([album: tracks]), forKey: "OfflineDB:AlbumTracks")
		if !dates.isEmpty {
			offlineLibrary.defaults.set(try? encoder.encode(dates), forKey: "OfflineDB:TrackAddedDates")
		}
	}

	/// A file dated so a test can tell a backfilled date from "now". It carries a real FLAC header,
	/// so the sync's verifier accepts it: these tests are about the sync's keep and date paths, and a
	/// stub the verifier rejects would send the sync off to resolve and download the track instead.
	private func createOfflineFile(forTrackId trackId: Int, createdAt date: Date) throws {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent("\(trackId).lossless.flac")
		let bytes = Data("fLaC".utf8) + Data(repeating: 0, count: HLSStreaming.minimumPlayableFileBytes)
		try bytes.write(to: file)
		try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: file.path)
	}

	private func makeTrack(id: Int) -> Track {
		Track(
			id: id,
			title: "Offline Pin Test",
			duration: 180,
			replayGain: 0,
			peak: nil,
			allowStreaming: true,
			streamReady: true,
			streamStartDate: nil,
			premiumStreamingOnly: nil,
			trackNumber: 1,
			volumeNumber: 1,
			version: nil,
			popularity: 0,
			copyright: nil,
			description: nil,
			url: URL(string: "https://tidal.com/track/\(id)")!,
			isrc: nil,
			editable: false,
			explicit: false,
			audioQuality: .high,
			audioModes: [.stereo],
			artist: nil,
			artists: [],
			album: makeAlbum(id: id),
			mixes: nil,
			dateAdded: nil,
			index: nil,
			itemUuid: nil,
			bpm: nil,
			key: nil,
			keyScale: nil
		)
	}

	private func makeAlbum(id: Int) -> Album {
		Album(
			id: id,
			title: "Offline Pin Test",
			duration: nil,
			streamReady: nil,
			streamStartDate: nil,
			allowStreaming: nil,
			premiumStreamingOnly: nil,
			numberOfTracks: nil,
			numberOfVideos: nil,
			numberOfVolumes: nil,
			releaseDate: nil,
			copyright: nil,
			type: nil,
			version: nil,
			url: nil,
			cover: nil,
			videoCover: nil,
			explicit: false,
			upc: nil,
			popularity: nil,
			audioQuality: .high,
			audioModes: [.stereo],
			artist: nil,
			artists: nil
		)
	}
}
