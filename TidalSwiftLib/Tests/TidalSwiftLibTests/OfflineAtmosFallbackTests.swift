//
//  OfflineAtmosFallbackTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// A track that Tidal can only serve as Dolby Atmos must still download, and the
/// sync must stop fighting the file it just wrote.
///
/// `streamUrl` refuses an Atmos-capable track at every tier, but the manifest
/// endpoint answers it with the Atmos rendition even with the Atmos preference
/// off. The sync therefore accepts either rendition for such a track: with the
/// preference off, an Atmos file already on disk must be neither re-resolved
/// (re-downloaded) nor pruned. Everything runs against the temporary library
/// root from `TemporaryOfflineLibrary`, never the real folder or the network.
///
/// The neighbouring cases the fallback must not disturb are covered elsewhere:
/// a stereo track's file name and the replace-on-quality-change behaviour live in
/// `OfflineWantedSetTests.testAtmosPreferenceChangesTheWantedFileName` and
/// `OfflineSyncOrderTests.testSuccessfulQualitySwitchReplacesTheFile`.
@MainActor
final class OfflineAtmosFallbackTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineAtmosFallback")

	/// Counts how often the sync asked the seam for a stream, so a second pass
	/// that re-resolves the track is distinguishable from one that leaves it alone.
	private var seamCallCount = 0

	/// The keys `OfflineDB` touches plus the Atmos preference, snapshotted so the
	/// test runner's defaults are restored afterwards.
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
		seamCallCount = 0
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

	/// (a) A dual-format track with the Atmos preference off, whose resolution
	/// falls back to the manifest's Atmos stream, is downloaded and stored with
	/// the Atmos marker.
	func testDualFormatTrackWithPreferenceOffStoresTheAtmosFile() async throws {
		let trackId = 642_000_001
		let session = makeSession(offlineAudioQuality: .high)
		let offline = session.helpers.offline
		XCTAssertFalse(offline.preferDolbyAtmos, "this test is about the preference being off")

		let fixture = try silentM4AFixture()
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: true)
		}
		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])

		await offline.awaitOngoingSync()

		XCTAssertEqual(
			try libraryFileNames(),
			["\(trackId).atmos.m4a"],
			"a dual-format track whose stereo stream is refused must be stored from the Atmos fallback"
		)
	}

	/// (b) A second sync with that Atmos file already on disk neither re-downloads
	/// it nor deletes it. The resolution seam was already called once for the
	/// download; a second call would mean the sync put the track back in `toAdd`
	/// because it does not accept the Atmos file as the wanted rendition.
	func testSecondSyncKeepsTheAtmosFileWithoutResolvingItAgain() async throws {
		let trackId = 642_000_002
		let session = makeSession(offlineAudioQuality: .high)
		let offline = session.helpers.offline

		let fixture = try silentM4AFixture()
		offline.resolveOfflineStream = { [weak self] _ in
			self?.seamCallCount += 1
			return AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: true)
		}

		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(seamCallCount, 1, "the first sync must download the track once")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).atmos.m4a"])

		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(seamCallCount, 1, "a second sync must not resolve the already-stored track again")
		XCTAssertEqual(
			try libraryFileNames(),
			["\(trackId).atmos.m4a"],
			"a second sync must neither re-download nor prune the Atmos file"
		)
	}

	/// (c) A dual-format track with the preference on still resolves to Atmos and
	/// stores the Atmos file.
	func testDualFormatTrackWithPreferenceOnStoresTheAtmosFile() async throws {
		let trackId = 642_000_003
		let session = makeSession(offlineAudioQuality: .high)
		let offline = session.helpers.offline
		offline.setPreferDolbyAtmos(to: true)

		let fixture = try silentM4AFixture()
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: true)
		}
		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])

		await offline.awaitOngoingSync()

		XCTAssertEqual(try libraryFileNames(), ["\(trackId).atmos.m4a"])
	}

	/// (e) A track removed from the offline set loses every file it had, whichever
	/// rendition that was. Here it held the Atmos file. The removal is explicit: the
	/// sync no longer reads "no longer in the set" as "delete", so that a database
	/// which failed to load cannot empty the library.
	func testTrackLeavingTheOfflineSetRemovesTheAtmosFile() async throws {
		let trackId = 642_000_005
		let session = makeSession(offlineAudioQuality: .high)
		let offline = session.helpers.offline

		let fixture = try silentM4AFixture()
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: true)
		}

		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])
		await offline.awaitOngoingSync()
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).atmos.m4a"])

		offline.setOfflineTracksForTesting([])
		await offline.remove(track: makeDualFormatTrack(id: trackId))
		await offline.awaitOngoingSync()

		XCTAssertEqual(try libraryFileNames(), [], "a track that left the offline set must lose its file")
	}

	// MARK: - Helpers

	private func makeSession(offlineAudioQuality: AudioQuality) -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: offlineAudioQuality
		))
	}

	private func libraryFileNames() throws -> [String] {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	private func silentM4AFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "m4a", subdirectory: "Fixtures"))
	}

	/// A track Tidal advertises as both STEREO and DOLBY_ATMOS, the shape whose
	/// `streamUrl` is refused at every tier.
	private func makeDualFormatTrack(id: Int) -> Track {
		let artist = Artist(
			id: 1, name: "Tester", artistTypes: nil, url: nil, picture: nil,
			popularity: nil, type: nil, banner: nil, relationType: nil
		)
		let album = Album(
			id: 2, title: "Test Album", duration: nil, streamReady: nil, streamStartDate: nil,
			allowStreaming: nil, premiumStreamingOnly: nil, numberOfTracks: nil, numberOfVideos: nil,
			numberOfVolumes: nil, releaseDate: nil, copyright: nil, type: nil, version: nil,
			url: nil, cover: nil, videoCover: nil, explicit: false, upc: nil, popularity: nil,
			audioQuality: nil, audioModes: [.stereo, .dolbyAtmos], artist: artist, artists: nil
		)
		return Track(
			id: id, title: "Test Track", duration: 1, replayGain: 0, peak: nil,
			allowStreaming: true, streamReady: true, streamStartDate: nil, premiumStreamingOnly: nil,
			trackNumber: 1, volumeNumber: 1, version: nil, popularity: 1, copyright: nil,
			description: nil, url: URL(string: "https://tidal.com/track/\(id)")!, isrc: nil,
			editable: false, explicit: false, audioQuality: .high, audioModes: [.stereo, .dolbyAtmos],
			artist: artist, artists: [artist], album: album, mixes: nil, dateAdded: nil,
			index: nil, itemUuid: nil, bpm: nil, key: nil, keyScale: nil
		)
	}
}
