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
