//
//  OfflineHiResTests.swift
//  TidalSwiftLibTests
//

import AVFoundation
import XCTest
@testable import TidalSwiftLib

/// A track the sync downloads through the hi-res route ends up on disk decrypted and
/// playable; an encrypted file left in the offline library would be silent corruption.
@MainActor
final class OfflineHiResTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineHiRes")

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	func testSyncWritesADecryptedPlayableHiResFile() async throws {
		let trackId = 779_000_001
		let libraryDirectory = try makeLibraryDirectory()
		let encrypted = try EncryptedFLACFixture.make(in: offlineLibrary.root)

		let session = try makeSession()
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		let downloads = Counter()
		offline.resolveHiResOfflineStream = { _ in
			downloads.value += 1
			return AcceptedHiResManifest(url: encrypted.url, keyId: encrypted.keyId)
		}

		await offline.awaitOngoingSync()

		let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
		XCTAssertEqual(files, ["\(trackId).hires.flac"], "the sync must store one decrypted hi-res file")

		let fileURL = libraryDirectory.appendingPathComponent("\(trackId).hires.flac")
		let original = try AVAudioFile(forReading: try silentFlacFixture())
		let stored = try AVAudioFile(forReading: fileURL)
		XCTAssertEqual(stored.length, original.length, "the stored file must decode as the source audio")
		XCTAssertEqual(stored.fileFormat.sampleRate, original.fileFormat.sampleRate)

		// A decrypted hi-res file satisfies the wanted variant, so the next sync keeps it.
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(downloads.value, 1, "the decrypted file must be recognised, not re-downloaded")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).hires.flac"])
	}

	/// A dual-format track with the Atmos preference on is wanted in Atmos, so even a
	/// session that can use the hi-res stereo route must not take it.
	func testDualFormatTrackWithAtmosPreferenceStoresTheAtmosFileOnACapableSession() async throws {
		let trackId = 779_000_002
		offlineLibrary.defaults.set(true, forKey: "offlinePreferDolbyAtmos")
		_ = try makeLibraryDirectory()
		let encrypted = try EncryptedFLACFixture.make(in: offlineLibrary.root)

		let session = try makeSession()
		let offline = session.helpers.offline
		XCTAssertTrue(offline.preferDolbyAtmos, "this test is about the Atmos preference being on")

		let hiRes = Counter()
		offline.resolveHiResOfflineStream = { _ in
			hiRes.value += 1
			return AcceptedHiResManifest(url: encrypted.url, keyId: encrypted.keyId)
		}
		let streams = Counter()
		let fixture = try silentM4AFixture()
		offline.resolveOfflineStream = { _ in
			streams.value += 1
			return AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: true)
		}

		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(hiRes.value, 0, "the Atmos preference must keep the sync off the hi-res stereo route")
		XCTAssertEqual(
			try libraryFileNames(),
			["\(trackId).atmos.m4a"],
			"a dual-format track with the preference on must be stored as Atmos"
		)

		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(streams.value, 1, "the stored Atmos file must satisfy the wish, so a second sync must not resolve the track again")
		XCTAssertEqual(hiRes.value, 0, "the hi-res route must stay unused on both passes")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).atmos.m4a"])
	}

	// MARK: - Helpers

	private final class Counter {
		var value = 0
	}

	private func makeLibraryDirectory() throws -> URL {
		let libraryDirectory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
		return libraryDirectory
	}

	private func libraryFileNames() throws -> [String] {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	private func silentFlacFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "flac", subdirectory: "Fixtures"))
	}

	private func silentM4AFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "m4a", subdirectory: "Fixtures"))
	}

	/// A track Tidal advertises as both STEREO and DOLBY_ATMOS, the shape that has a
	/// stereo rendition for the hi-res route and an Atmos one for the preference.
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

	/// A session whose token carries the `cuk` claim the hi-res route needs.
	private func makeSession() throws -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: try Self.tokenWithCukClaim(),
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: .high
		))
	}

	private static func tokenWithCukClaim() throws -> String {
		let data = try JSONSerialization.data(withJSONObject: ["uid": 1, "cuk": "client-key"])
		let body = data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return "Bearer .\(body).signature"
	}

	private func makeTrack(id: Int) -> Track {
		let artist = Artist(
			id: 1, name: "Tester", artistTypes: nil, url: nil, picture: nil,
			popularity: nil, type: nil, banner: nil, relationType: nil
		)
		let album = Album(
			id: 2, title: "Test Album", duration: nil, streamReady: nil, streamStartDate: nil,
			allowStreaming: nil, premiumStreamingOnly: nil, numberOfTracks: nil, numberOfVideos: nil,
			numberOfVolumes: nil, releaseDate: nil, copyright: nil, type: nil, version: nil,
			url: nil, cover: nil, videoCover: nil, explicit: false, upc: nil, popularity: nil,
			audioQuality: nil, audioModes: [.stereo], artist: artist, artists: nil
		)
		return Track(
			id: id, title: "Test Track", duration: 1, replayGain: 0, peak: nil,
			allowStreaming: true, streamReady: true, streamStartDate: nil, premiumStreamingOnly: nil,
			trackNumber: 1, volumeNumber: 1, version: nil, popularity: 1, copyright: nil,
			description: nil, url: URL(string: "https://tidal.com/track/\(id)")!, isrc: nil,
			editable: false, explicit: false, audioQuality: .high, audioModes: [.stereo],
			artist: artist, artists: [artist], album: album, mixes: nil, dateAdded: nil,
			index: nil, itemUuid: nil, bpm: nil, key: nil, keyScale: nil
		)
	}
}
