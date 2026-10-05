//
//  TemporaryOfflineLibraryTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Guards the two properties that keep the rest of the suite off this machine's
/// real account and real music folder. Both were violated once already: a test
/// session loaded the developer's stored Tidal token, and `Offline.init` started
/// a sync against `~/Music/TidalSwift Offline Library` that removes any audio
/// file it cannot find in its database.
@MainActor
final class TemporaryOfflineLibraryTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "IsolationGuard")

	/// The keys `OfflineDB` reads and writes. Pinning a track calls `save`, which
	/// persists the whole database; without this snapshot a test would overwrite
	/// whatever the test runner's UserDefaults domain holds.
	private let offlineDBKeys = [
		"OfflineDB:Tracks",
		"OfflineDB:TrackAddedDates",
		"OfflineDB:FavoriteTracks",
		"OfflineDB:Albums",
		"OfflineDB:AlbumTracks",
		"OfflineDB:Playlists",
		"OfflineDB:PlaylistTracks",
		"OfflineDB:StandaloneOfflineTracks"
	]
	private var savedDefaults: [String: Any] = [:]

	override func setUp() {
		super.setUp()
		for key in offlineDBKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
		for key in offlineDBKeys { UserDefaults.standard.removeObject(forKey: key) }
	}

	override func tearDown() {
		for key in offlineDBKeys {
			if let value = savedDefaults[key] {
				UserDefaults.standard.set(value, forKey: key)
			} else {
				UserDefaults.standard.removeObject(forKey: key)
			}
		}
		savedDefaults = [:]
		offlineLibrary.remove()
		super.tearDown()
	}

	/// `Session(config: nil)` calls `Config.load()`, which reads whatever is
	/// stored under "Config Information" — a real account token on a developer
	/// machine. A test session must not carry one.
	func testSessionDoesNotUseAStoredAccount() {
		let session = offlineLibrary.makeSession()
		XCTAssertTrue(session.config.accessToken.isEmpty, "test session carries a stored access token")
		XCTAssertTrue(session.config.refreshToken.isEmpty, "test session carries a stored refresh token")
	}

	/// The offline root must be a throwaway directory, never the Music folder.
	func testOfflineRootIsTemporary() {
		let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
		XCTAssertTrue(
			offlineLibrary.root.standardizedFileURL.path.hasPrefix(temporary),
			"offline root is outside the temporary directory: \(offlineLibrary.root.path)"
		)
	}

	/// A track pinned from the context menu is not a favourite, an album or a
	/// playlist, so the sync's wanted set (`db.tracks`) must take it from the
	/// standalone set. Otherwise the sync would delete its file on the next run.
	func testPinnedTrackStaysInTheSyncWantedSetWithoutBeingAFavourite() {
		let db = OfflineDB()
		let track = makeTrack(id: 987_654_321)

		db.addStandaloneOfflineTrack(track)

		XCTAssertFalse(db.favoriteTracks.contains(track), "the pinned track must not be a favourite for this test to mean anything")
		XCTAssertTrue(db.tracks.contains(track), "a pinned track must be part of the offline set even though it is not a favourite")
	}

	/// Unpinning a track that no other source holds must drop it from the wanted
	/// set, which is what makes the sync delete its file.
	func testRemovingThePinMakesTheTrackEligibleForRemoval() {
		let db = OfflineDB()
		let track = makeTrack(id: 987_654_322)

		db.addStandaloneOfflineTrack(track)
		db.removeStandaloneOfflineTrack(track)

		XCTAssertFalse(db.tracks.contains(track), "an unpinned track held by no favourite, album or playlist must leave the offline set")
	}

	/// The pinned set is persisted, so it survives an app relaunch (`OfflineDB`
	/// re-reads UserDefaults in `init`).
	func testPinnedTracksArePersistedAndReloaded() {
		let track = makeTrack(id: 987_654_323)

		OfflineDB().addStandaloneOfflineTrack(track)

		XCTAssertTrue(OfflineDB().tracks.contains(track), "a pinned track must be reloaded from the persisted set")
	}

	/// A track whose file is already on disk but whose date was lost must come
	/// back from the file's own creation date, not from "now". The setup writes
	/// the date into the file, so a "now" result would be clearly different.
	func testFileOnDiskWithoutStoredDateBackfillsFromItsCreationDate() throws {
		let trackId = 987_654_401
		let fileDate = Date(timeIntervalSince1970: 1_600_000_000)
		try createOfflineFile(forTrackId: trackId, createdAt: fileDate)
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)])

		let session = offlineLibrary.makeSession()
		let added = try XCTUnwrap(session.helpers.offline.addedDate(forTrackId: trackId))
		XCTAssertEqual(added.timeIntervalSince1970, fileDate.timeIntervalSince1970, accuracy: 1,
					   "a date must come from the file on disk, not the current time")
	}

	/// A date that already exists is history and must survive a load unchanged,
	/// even though the file on disk carries a different creation date.
	func testExistingAddedDateSurvivesAReload() throws {
		let trackId = 987_654_402
		let existingDate = Date(timeIntervalSince1970: 1_500_000_000)
		try createOfflineFile(forTrackId: trackId, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)], dates: [trackId: existingDate])

		let session = offlineLibrary.makeSession()
		let added = try XCTUnwrap(session.helpers.offline.addedDate(forTrackId: trackId))
		XCTAssertEqual(added.timeIntervalSince1970, existingDate.timeIntervalSince1970, accuracy: 1,
					   "an existing date must not be moved by a file that has a different creation date")
	}

	/// A wanted track that has no file yet still gets a date, so the offline list
	/// shows something as soon as the user asks for it.
	func testWantedTrackWithoutAFileStillGetsADate() throws {
		let trackId = 987_654_403
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)])

		let before = Date()
		let session = offlineLibrary.makeSession()
		let added = try XCTUnwrap(session.helpers.offline.addedDate(forTrackId: trackId))
		XCTAssertGreaterThanOrEqual(added.timeIntervalSince(before), -1, "a track with no file must fall back to now")
		XCTAssertLessThanOrEqual(added.timeIntervalSince(before), 5)
	}

	/// The backfilled dates are written, so they are still there after a reload
	/// rather than being recomputed (or lost) every launch.
	func testBackfilledAddedDatesArePersisted() throws {
		let trackId = 987_654_404
		let fileDate = Date(timeIntervalSince1970: 1_600_000_000)
		try createOfflineFile(forTrackId: trackId, createdAt: fileDate)
		persistOfflineState(album: makeAlbum(id: trackId), tracks: [makeTrack(id: trackId)])

		let session = offlineLibrary.makeSession()
		let inMemory = try XCTUnwrap(session.helpers.offline.addedDate(forTrackId: trackId))
		XCTAssertEqual(inMemory.timeIntervalSince1970, fileDate.timeIntervalSince1970, accuracy: 1)

		let reloaded = OfflineDB()
		let persisted = try XCTUnwrap(reloaded.trackAddedDates[trackId])
		XCTAssertEqual(persisted.timeIntervalSince1970, fileDate.timeIntervalSince1970, accuracy: 1,
					   "the backfilled date must be persisted, not just held in memory")
	}

	// MARK: - Helpers

	/// Writes the persisted offline state `OfflineDB` reads in `init`, so a test
	/// can drive the load path — where dates are backfilled — without a Tidal
	/// account or the real library.
	private func persistOfflineState(album: Album, tracks: [Track], dates: [Int: Date] = [:]) {
		let encoder = JSONEncoder()
		UserDefaults.standard.set(try? encoder.encode([album]), forKey: "OfflineDB:Albums")
		UserDefaults.standard.set(try? encoder.encode([album: tracks]), forKey: "OfflineDB:AlbumTracks")
		if !dates.isEmpty {
			UserDefaults.standard.set(try? encoder.encode(dates), forKey: "OfflineDB:TrackAddedDates")
		}
	}

	/// Creates the offline library folder with one track file, dated so a test can
	/// tell a backfilled date from "now".
	private func createOfflineFile(forTrackId trackId: Int, createdAt date: Date) throws {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent("\(trackId).lossless.flac")
		FileManager.default.createFile(atPath: file.path, contents: Data())
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
