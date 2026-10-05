//
//  HiResStreamCacheTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the playback cache: it stays bounded, it is pruned by age then size, it never
/// reaches outside its own directory, and a file already there is reused instead of
/// re-downloaded. Everything runs in a temporary directory, never the real caches.
@MainActor
final class HiResStreamCacheTests: XCTestCase {
	private var directory: URL!

	override func setUp() {
		super.setUp()
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("HiResStreamCacheTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: directory)
		directory = nil
		super.tearDown()
	}

	private func write(_ name: String, bytes: Int, modified: Date) throws -> URL {
		let url = directory.appendingPathComponent(name)
		try Data(repeating: 0, count: bytes).write(to: url)
		try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
		return url
	}

	/// Size cap: the oldest entries go first until the directory is under the cap.
	func testPruneRemovesOldestUntilUnderTheSizeCap() throws {
		let now = Date()
		let oldest = try write("oldest.flac", bytes: 1000, modified: now.addingTimeInterval(-300))
		let middle = try write("middle.flac", bytes: 1000, modified: now.addingTimeInterval(-200))
		let newest = try write("newest.flac", bytes: 1000, modified: now.addingTimeInterval(-100))

		let removed = HiResStreamCache.prune(in: directory, maxBytes: 2500, maxAge: .greatestFiniteMagnitude, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), [oldest.lastPathComponent])
		XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
	}

	/// Age cap: a file not touched within `maxAge` is dropped even when there is room.
	func testPruneRemovesFilesOlderThanMaxAge() throws {
		let now = Date()
		let stale = try write("stale.flac", bytes: 100, modified: now.addingTimeInterval(-8 * 24 * 60 * 60))
		let fresh = try write("fresh.flac", bytes: 100, modified: now.addingTimeInterval(-60))

		let removed = HiResStreamCache.prune(in: directory, maxBytes: .max, maxAge: 7 * 24 * 60 * 60, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), [stale.lastPathComponent])
		XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
	}

	/// Pruning is scoped to its directory, so the offline library (or anything else on
	/// disk) can never be a casualty of keeping the cache small.
	func testPruneDoesNotTouchAnythingOutsideItsDirectory() throws {
		let now = Date()
		let outside = FileManager.default.temporaryDirectory
			.appendingPathComponent("HiResStreamCacheTests-outside-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: outside) }
		let libraryFile = outside.appendingPathComponent("123.lossless.flac")
		try Data(repeating: 1, count: 1000).write(to: libraryFile)
		try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 24 * 60 * 60)], ofItemAtPath: libraryFile.path)

		_ = HiResStreamCache.prune(in: directory, maxBytes: 0, maxAge: 0, now: now)

		XCTAssertTrue(FileManager.default.fileExists(atPath: libraryFile.path), "pruning must never leave its directory")
	}

	/// A file already in the cache is handed back as the stream, so a replay does not
	/// download and decrypt again. The session has no reachable network, so a download
	/// attempt would fail: returning the cached file is the only way this passes.
	func testCachedFileIsReusedWithoutDownloading() async throws {
		let trackId = 779_500_001
		let cached = directory.appendingPathComponent("\(trackId).flac")
		try Data("already here".utf8).write(to: cached)

		let offlineLibrary = TemporaryOfflineLibrary(label: "HiResStreamCache")
		defer { offlineLibrary.remove() }
		let session = offlineLibrary.makeSession(config: Config(
			accessToken: Self.tokenWithCukClaim(),
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: .high
		))

		let playback = await HiResStreaming.playbackFile(
			for: makeTrack(id: trackId),
			session: session,
			cacheDirectory: directory
		)

		XCTAssertEqual(playback?.url, cached)
	}

	// MARK: - Helpers

	private static func tokenWithCukClaim() -> String {
		let payload: [String: Any] = ["uid": 1, "cuk": "client-key"]
		let data = try! JSONSerialization.data(withJSONObject: payload)
		let body = data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return "Bearer .\(body).signature"
	}

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
}
