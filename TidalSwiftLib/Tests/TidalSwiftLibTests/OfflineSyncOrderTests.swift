//
//  OfflineSyncOrderTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 05.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// The sync must never delete a file it cannot replace: downloads happen first,
/// and a track's old file goes only once its replacement is on disk. These live
/// apart from `TemporaryOfflineLibraryTests` because the two lanes that added
/// them met in a merge conflict there.
@MainActor
final class OfflineSyncOrderTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineSyncOrder")

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	func testFailedQualitySwitchKeepsTheExistingFile() async throws {
		let trackId = 778_000_001
		let libraryDirectory = try makeLibraryDirectory()
		// Already on disk at quality A (".high" is stored as `<id>.lossless.flac`)
		let existingFile = libraryDirectory.appendingPathComponent("\(trackId).lossless.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		// Sync at quality B (".medium" is stored as `<id>.high.m4a`)
		let session = makeSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		// A replacement that resolves to a file which cannot be downloaded is the
		// failing download the bug is about, without needing a live account.
		offline.resolveOfflineStream = { _ in
			AudioStream(
				url: URL(fileURLWithPath: NSTemporaryDirectory())
					.appendingPathComponent("missing-\(UUID().uuidString).flac"),
				pathExtension: "flac",
				isDolbyAtmos: false
			)
		}

		await offline.awaitOngoingSync()

		XCTAssertTrue(
			FileManager.default.fileExists(atPath: existingFile.path),
			"the sync deleted the old-quality file although its replacement failed"
		)
		let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
		XCTAssertEqual(files, ["\(trackId).lossless.flac"])
	}

	/// The behaviour that made variant pruning worthwhile still holds: after a
	/// successful re-download at the new quality, exactly one file remains.
	func testSuccessfulQualitySwitchReplacesTheFile() async throws {
		let trackId = 778_000_002
		let libraryDirectory = try makeLibraryDirectory()
		let existingFile = libraryDirectory.appendingPathComponent("\(trackId).lossless.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		let session = makeSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		// Downloading the fixture over a file URL succeeds without a network.
		offline.resolveOfflineStream = { _ in
			AudioStream(url: try! self.silentFlacFixture(), pathExtension: "flac", isDolbyAtmos: false)
		}

		await offline.awaitOngoingSync()

		let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
		XCTAssertEqual(files, ["\(trackId).high.flac"])
	}

	// MARK: - Helpers

	private func makeLibraryDirectory() throws -> URL {
		let libraryDirectory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
		return libraryDirectory
	}

	private func silentFlacFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "flac", subdirectory: "Fixtures"))
	}

	/// The session owns the `Offline` the sync runs on, and the test must keep the
	/// session alive (Offline's session reference is `unowned`), so build both and
	/// hold the session in a local. Setup must also stay synchronous: the init sync
	/// only starts once the test first suspends.
	private func makeSession(offlineAudioQuality: AudioQuality) -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: offlineAudioQuality
		))
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
