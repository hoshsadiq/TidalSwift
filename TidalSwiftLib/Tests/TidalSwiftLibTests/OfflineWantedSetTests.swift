//
//  OfflineWantedSetTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins what the offline sync keeps: which sources put a track in the wanted
/// set, that a date leaves with the track, and which file name a quality or
/// Atmos choice asks for. Everything runs against the temporary library root
/// from `TemporaryOfflineLibrary`, never the real folder or the network.
@MainActor
final class OfflineWantedSetTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineWantedSet")

	/// The keys `OfflineDB` reads and writes, plus the two preferences the sync
	/// consults. Snapshotting them keeps this test off the test runner's real
	/// defaults, the same way `TemporaryOfflineLibraryTests` does.
	private let defaultsKeys = [
		"OfflineDB:Tracks",
		"OfflineDB:TrackAddedDates",
		"OfflineDB:FavoriteTracks",
		"OfflineDB:Albums",
		"OfflineDB:AlbumTracks",
		"OfflineDB:Playlists",
		"OfflineDB:PlaylistTracks",
		"OfflineDB:StandaloneOfflineTracks",
		"SaveFavoritesOffline",
		"offlinePreferDolbyAtmos"
	]
	private var savedDefaults: [String: Any] = [:]

	override func setUp() {
		super.setUp()
		for key in defaultsKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
		for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
	}

	override func tearDown() {
		for key in defaultsKeys {
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

	// MARK: - Removing a source

	/// A track stored through an offline album must leave the wanted set, and
	/// take its added date with it, once the album is removed.
	func testRemovingAnOfflineAlbumDropsItsTrackAndDate() async {
		let track = makeTrack(id: 641_000_001)
		persistAlbums([track.album], tracks: [track.album: [track]])
		persistDates([track.id: Date(timeIntervalSince1970: 1_600_000_000)])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }

		let wantedBefore = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertTrue(wantedBefore, "the album must put the track in the wanted set")
		XCTAssertNotNil(offline.addedDate(forTrackId: track.id))

		await offline.remove(album: track.album)

		let wantedAfter = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertFalse(wantedAfter, "removing the album must drop the track")
		XCTAssertNil(offline.addedDate(forTrackId: track.id), "the date must leave with the track")
	}

	/// The same rule for a track stored only through an offline playlist.
	func testRemovingAnOfflinePlaylistDropsItsTrackAndDate() async {
		let track = makeTrack(id: 641_000_002)
		let playlist = makePlaylist(uuid: "offline-wanted-set-playlist")
		persistPlaylists([playlist], tracks: [playlist: [track]])
		persistDates([track.id: Date(timeIntervalSince1970: 1_600_000_000)])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }

		let wantedBefore = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertTrue(wantedBefore, "the playlist must put the track in the wanted set")
		XCTAssertNotNil(offline.addedDate(forTrackId: track.id))

		await offline.remove(playlist: playlist)

		let wantedAfter = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertFalse(wantedAfter, "removing the playlist must drop the track")
		XCTAssertNil(offline.addedDate(forTrackId: track.id), "the date must leave with the track")
	}

	// MARK: - Favourites

	/// A favourite only reaches the wanted set when the save-favourites-offline
	/// preference has let the sync store it. With the preference on, the stored
	/// favourite contributes like any other source.
	func testStoredFavouriteIsPartOfTheWantedSet() async {
		let track = makeTrack(id: 641_000_003)
		persistFavorites([track])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }

		let wanted = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertTrue(wanted, "a stored favourite must be wanted")
	}

	/// With the preference off, the favourite sync clears the stored favourites,
	/// so the track and its date leave the wanted set.
	func testTurningSaveFavoritesOfflineOffDropsFavouritesFromTheWantedSet() async {
		let track = makeTrack(id: 641_000_004)
		UserDefaults.standard.set(false, forKey: "SaveFavoritesOffline")
		persistFavorites([track])
		persistDates([track.id: Date(timeIntervalSince1970: 1_600_000_000)])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }

		let wantedBefore = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertTrue(wantedBefore)

		offline.asyncSyncFavoriteTracks()
		let dropped = await waitUntil { !(await offline.isTrackMarkedForOffline(track: track)) }

		XCTAssertTrue(dropped, "with the preference off the favourite must leave the wanted set")
		XCTAssertNil(offline.addedDate(forTrackId: track.id), "the date must leave with the favourite")
	}

	// MARK: - Two sources

	/// A track that is both pinned and a favourite survives removing either one
	/// source, because the other still holds it.
	func testPinnedFavouriteSurvivesRemovingOneSource() async {
		let track = makeTrack(id: 641_000_005)
		persistFavorites([track])
		persistDates([track.id: Date(timeIntervalSince1970: 1_600_000_000)])

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }

		let wantedBefore = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertTrue(wantedBefore, "the favourite alone must make the track wanted")

		await offline.add(track: track)
		await offline.remove(track: track)

		let wantedAfter = await offline.isTrackMarkedForOffline(track: track)
		XCTAssertTrue(wantedAfter, "removing the pin must not drop a track the favourite still holds")
		XCTAssertNotNil(offline.addedDate(forTrackId: track.id), "the date must survive removing one of two sources")
	}

	// MARK: - File variant

	/// The file name a sync asks for follows the offline quality and the Atmos
	/// preference, so flipping the Atmos preference replaces the stored file.
	func testAtmosPreferenceChangesTheWantedFileName() async throws {
		let trackId = 641_000_006
		let track = makeTrack(id: trackId, audioModes: [.stereo, .dolbyAtmos])
		let fixture = try silentFlacFixture()

		let session = offlineLibrary.makeSession(config: Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: .high
		))
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([track])
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "flac", isDolbyAtmos: false)
		}

		await offline.awaitOngoingSync()
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).lossless.flac"], "a stereo track must be stored under its quality")

		// The preference picks the Atmos rendition, so the next sync downloads the
		// .atmos.m4a name and prunes the stereo file.
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: true)
		}
		offline.setPreferDolbyAtmos(to: true)
		await offline.awaitOngoingSync()

		XCTAssertEqual(try libraryFileNames(), ["\(trackId).atmos.m4a"], "the Atmos preference must change the file name")
	}

	// MARK: - Helpers

	/// Polls a MainActor condition while letting the sync tasks run. Bounded so a
	/// broken sync fails the test instead of hanging it.
	private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await condition() { return true }
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		return await condition()
	}

	private func libraryFileNames() throws -> [String] {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	private func silentFlacFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "flac", subdirectory: "Fixtures"))
	}

	// MARK: - Persisted state

	private func persistFavorites(_ tracks: [Track]) {
		UserDefaults.standard.set(try? JSONEncoder().encode(tracks), forKey: "OfflineDB:FavoriteTracks")
	}

	private func persistAlbums(_ albums: [Album], tracks: [Album: [Track]]) {
		UserDefaults.standard.set(try? JSONEncoder().encode(albums), forKey: "OfflineDB:Albums")
		UserDefaults.standard.set(try? JSONEncoder().encode(tracks), forKey: "OfflineDB:AlbumTracks")
	}

	private func persistPlaylists(_ playlists: [Playlist], tracks: [Playlist: [Track]]) {
		UserDefaults.standard.set(try? JSONEncoder().encode(playlists), forKey: "OfflineDB:Playlists")
		UserDefaults.standard.set(try? JSONEncoder().encode(tracks), forKey: "OfflineDB:PlaylistTracks")
	}

	private func persistDates(_ dates: [Int: Date]) {
		UserDefaults.standard.set(try? JSONEncoder().encode(dates), forKey: "OfflineDB:TrackAddedDates")
	}

	// MARK: - Model builders

	private func makeTrack(id: Int, audioModes: [AudioMode] = [.stereo]) -> Track {
		let artist = Artist(
			id: 1, name: "Tester", artistTypes: nil, url: nil, picture: nil,
			popularity: nil, type: nil, banner: nil, relationType: nil
		)
		let album = Album(
			id: 2, title: "Test Album", duration: nil, streamReady: nil, streamStartDate: nil,
			allowStreaming: nil, premiumStreamingOnly: nil, numberOfTracks: nil, numberOfVideos: nil,
			numberOfVolumes: nil, releaseDate: nil, copyright: nil, type: nil, version: nil,
			url: nil, cover: nil, videoCover: nil, explicit: false, upc: nil, popularity: nil,
			audioQuality: nil, audioModes: audioModes, artist: artist, artists: nil
		)
		return Track(
			id: id, title: "Test Track", duration: 1, replayGain: 0, peak: nil,
			allowStreaming: true, streamReady: true, streamStartDate: nil, premiumStreamingOnly: nil,
			trackNumber: 1, volumeNumber: 1, version: nil, popularity: 1, copyright: nil,
			description: nil, url: URL(string: "https://tidal.com/track/\(id)")!, isrc: nil,
			editable: false, explicit: false, audioQuality: .high, audioModes: audioModes,
			artist: artist, artists: [artist], album: album, mixes: nil, dateAdded: nil,
			index: nil, itemUuid: nil, bpm: nil, key: nil, keyScale: nil
		)
	}

	private func makePlaylist(uuid: String) -> Playlist {
		Playlist(
			uuid: uuid,
			title: "Test Playlist",
			numberOfTracks: 1,
			numberOfVideos: 0,
			creator: PlaylistCreator(id: 1, name: "Tester", url: nil, picture: nil, popularity: nil),
			description: nil,
			duration: 1,
			lastUpdated: Date(timeIntervalSince1970: 1_600_000_000),
			created: Date(timeIntervalSince1970: 1_600_000_000),
			type: .user,
			publicPlaylist: false,
			url: URL(string: "https://tidal.com/playlist/\(uuid)")!,
			image: nil,
			popularity: 0,
			squareImage: nil
		)
	}
}
