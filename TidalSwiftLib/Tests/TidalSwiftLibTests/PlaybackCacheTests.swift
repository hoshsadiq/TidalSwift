//
//  PlaybackCacheTests.swift
//  TidalSwiftLibTests
//

import Foundation
import XCTest
@testable import TidalSwiftLib

/// Pins the playback cache and the prefetcher: the cache stays bounded, LRU evicts the oldest
/// while sparing the prefetch window, and the browsing guard stops then resumes preparing.
@MainActor
final class PlaybackCacheTests: XCTestCase {
	private var directory: URL!

	override func setUp() {
		super.setUp()
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("PlaybackCacheTests-\(UUID().uuidString)", isDirectory: true)
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

	// MARK: - Pruning

	/// The least recently used entries go first until the directory is under the cap.
	func testPruneRemovesOldestUntilUnderTheSizeCap() throws {
		let now = Date()
		let oldest = try write("1-HI_RES_LOSSLESS.m4a", bytes: 1000, modified: now.addingTimeInterval(-300))
		let middle = try write("2-HI_RES_LOSSLESS.m4a", bytes: 1000, modified: now.addingTimeInterval(-200))
		let newest = try write("3-HI_RES_LOSSLESS.m4a", bytes: 1000, modified: now.addingTimeInterval(-100))

		let removed = PlaybackCache.prune(in: directory, maxBytes: 2500, maxAge: .greatestFiniteMagnitude, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), [oldest.lastPathComponent])
		XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
	}

	func testPruneRemovesFilesOlderThanMaxAge() throws {
		let now = Date()
		let stale = try write("10-HI_RES_LOSSLESS.m4a", bytes: 100, modified: now.addingTimeInterval(-8 * 24 * 60 * 60))
		let fresh = try write("11-HI_RES_LOSSLESS.m4a", bytes: 100, modified: now.addingTimeInterval(-60))

		let removed = PlaybackCache.prune(in: directory, maxBytes: .max, maxAge: 7 * 24 * 60 * 60, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), [stale.lastPathComponent])
		XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
	}

	/// A file prepared for playback is exempt from eviction, or the prefetch would be pointless.
	func testProtectedTrackIsNeverEvicted() throws {
		let now = Date()
		let oldest = try write("100-HI_RES_LOSSLESS.m4a", bytes: 1000, modified: now.addingTimeInterval(-300))
		let newer = try write("200-HI_RES_LOSSLESS.m4a", bytes: 1000, modified: now.addingTimeInterval(-100))

		let removed = PlaybackCache.prune(in: directory, maxBytes: 0, maxAge: .greatestFiniteMagnitude, protecting: [100], now: now)

		XCTAssertFalse(removed.map(\.lastPathComponent).contains(oldest.lastPathComponent))
		XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path), "protected track must survive the size cap")
		XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
	}

	/// The window is not aged out from under the player either.
	func testProtectedTrackSurvivesTheAgeCap() throws {
		let now = Date()
		let old = try write("300-HI_RES_LOSSLESS.m4a", bytes: 100, modified: now.addingTimeInterval(-8 * 24 * 60 * 60))

		let removed = PlaybackCache.prune(in: directory, maxBytes: .max, maxAge: 7 * 24 * 60 * 60, protecting: [300], now: now)

		XCTAssertTrue(removed.isEmpty)
		XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
	}

	// MARK: - Unified budget

	/// Every tier's file is one shape, so the usage total and the eviction order cover them all.
	func testCacheFilesShareOneBudget() throws {
		_ = try write("600-HI_RES_LOSSLESS.m4a", bytes: 1500, modified: Date())
		_ = try write("601-LOSSLESS.m4a", bytes: 500, modified: Date())

		XCTAssertEqual(PlaybackCache.usageBytes(in: directory), 2000)
	}

	func testEvictionTakesTheOldestFile() throws {
		let now = Date()
		let older = try write("700-HIGH.m4a", bytes: 1000, modified: now.addingTimeInterval(-300))
		let newer = try write("701-HI_RES_LOSSLESS.m4a", bytes: 1000, modified: now.addingTimeInterval(-100))

		let removed = PlaybackCache.prune(in: directory, maxBytes: 1500, maxAge: .greatestFiniteMagnitude, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), [older.lastPathComponent])
		XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
	}

	/// Pruning is scoped to its directory, so the offline library can never be a casualty.
	func testPruneDoesNotTouchAnythingOutsideItsDirectory() throws {
		let now = Date()
		let outside = FileManager.default.temporaryDirectory
			.appendingPathComponent("PlaybackCacheTests-outside-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: outside) }
		let libraryFile = outside.appendingPathComponent("123.lossless.m4a")
		try Data(repeating: 1, count: 1000).write(to: libraryFile)
		try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 24 * 60 * 60)], ofItemAtPath: libraryFile.path)

		_ = PlaybackCache.prune(in: directory, maxBytes: 0, maxAge: 0, now: now)

		XCTAssertTrue(FileManager.default.fileExists(atPath: libraryFile.path), "pruning must never leave its directory")
	}

	func testUsageCountsCacheBytes() throws {
		_ = try write("400-HI_RES_LOSSLESS.m4a", bytes: 1500, modified: Date())
		_ = try write("500-LOSSLESS.m4a", bytes: 500, modified: Date())

		XCTAssertEqual(PlaybackCache.usageBytes(in: directory), 2000)
	}

	// MARK: - Quality in the cache key

	/// The name carries the quality, so a file cached at one tier is never served at another;
	/// otherwise a Max play followed by a Lossless play reuses the 24-bit file.
	func testCacheKeysDifferPerQuality() {
		let urls = AudioQuality.allCases.map { PlaybackCache.fileURL(forTrackId: 779_500_002, rung: .stereo($0), in: directory) }
		XCTAssertEqual(Set(urls).count, urls.count, "the cached file name must carry the quality")
	}

	// MARK: - Prefetch window

	/// The tracks after the current one, in queue order, and never wrapping.
	func testPrefetchWindowFollowsQueueOrder() {
		let queue = makeTracks(ids: [10, 20, 30, 40, 50])

		XCTAssertEqual(
			PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 3).map(\.id),
			[20, 30, 40]
		)
		XCTAssertEqual(
			PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 2, depth: 3).map(\.id),
			[40, 50]
		)
	}

	func testPrefetchDepthIsRespected() {
		let queue = makeTracks(ids: [10, 20, 30, 40, 50])

		XCTAssertTrue(PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 0).isEmpty)
		XCTAssertEqual(
			PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 2).map(\.id),
			[20, 30]
		)
		XCTAssertEqual(
			PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 15).map(\.id),
			[20, 30, 40, 50]
		)
	}

	/// The policy is asked with whatever the controls and the queue hold, so it must not trap.
	func testNegativeDepthAndOutOfRangeIndexYieldNothing() {
		let queue = makeTracks(ids: [10, 20, 30])

		XCTAssertTrue(PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: -1).isEmpty)
		XCTAssertTrue(PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 3, depth: 3).isEmpty)
		XCTAssertTrue(PlaybackPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: -1, depth: 3).isEmpty)
		XCTAssertTrue(PlaybackPrefetchPolicy.upcomingTracks(queue: [], currentIndex: 0, depth: 3).isEmpty)
	}

	func testWindowSkipsCachedAndIneligibleTracks() {
		let queue = makeTracks(ids: [10, 20, 30, 40])

		let window = PlaybackPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: 0,
			depth: 3,
			shouldPrepare: { $0.id != 30 },
			isCached: { $0.id == 20 }
		)

		XCTAssertEqual(window.map(\.id), [40])
	}

	func testHighQualityQueuePreparesItsUpcomingTracks() {
		let queue = makeTracks(ids: [10, 20, 30, 40])

		let window = PlaybackPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: 0,
			depth: 2,
			shouldPrepare: { _ in
				PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: true)
			}
		)

		XCTAssertEqual(window.map(\.id), [20, 30])
	}

	/// The prepared cache is what keeps that uniform choice instant at playback time.
	func testLosslessStereoQueuePreparesItsUpcomingTracks() {
		let queue = makeTracks(ids: [10, 20, 30])

		let window = PlaybackPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: 0,
			depth: 3,
			shouldPrepare: { _ in
				PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: true)
			}
		)

		XCTAssertEqual(window.map(\.id), [20, 30])
	}

	// MARK: - Prefetch behaviour

	/// Three skips in a row stop preparing until a track settles, then preparing resumes.
	func testThreeSkipsStopPreparingAndSettlingResumesIt() async {
		var prepared: [Int] = []
		let prefetcher = PlaybackPrefetcher(
			settleInterval: 0.2,
			depthProvider: { 2 },
			shouldPrepare: { _ in true },
			isCached: { _ in false },
			prepare: { track, _, _ in prepared.append(track.id) }
		)
		let queue = makeTracks(ids: [10, 20, 30, 40])

		prefetcher.queueChanged(queue: queue, currentIndex: 0)
		await waitUntil { prepared.count == 2 }
		XCTAssertEqual(prepared, [20, 30])

		prefetcher.trackSkipped()
		prefetcher.trackSkipped()
		prefetcher.trackSkipped()
		XCTAssertTrue(prefetcher.isPausedForBrowsing)

		prefetcher.queueChanged(queue: queue, currentIndex: 1)
		await Task.yield()
		XCTAssertEqual(prepared, [20, 30], "preparing must stop while browsing")

		await waitUntil(timeout: 1.0) { !prefetcher.isPausedForBrowsing && prepared.count == 4 }
		XCTAssertFalse(prefetcher.isPausedForBrowsing)
		XCTAssertEqual(prepared, [20, 30, 30, 40], "preparing resumes with the window at the new track")
	}

	func testTwoSkipsDoNotStopPreparing() async {
		var prepared: [Int] = []
		let prefetcher = PlaybackPrefetcher(
			settleInterval: 0.05,
			depthProvider: { 1 },
			prepare: { track, _, _ in prepared.append(track.id) }
		)
		let queue = makeTracks(ids: [10, 20, 30])

		prefetcher.trackSkipped()
		prefetcher.trackSkipped()
		XCTAssertFalse(prefetcher.isPausedForBrowsing)

		prefetcher.queueChanged(queue: queue, currentIndex: 0)
		await waitUntil { prepared.count == 1 }
		XCTAssertEqual(prepared, [20])
	}

	func testPrefetchAndPruneStayOutOfTheOfflineLibrary() async {
		let offlineLibrary = FileManager.default.temporaryDirectory
			.appendingPathComponent("PlaybackCacheTests-library-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: offlineLibrary, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: offlineLibrary) }
		let libraryFile = offlineLibrary.appendingPathComponent("123.lossless.m4a")
		try? Data(repeating: 3, count: 1000).write(to: libraryFile)

		let prefetcher = PlaybackPrefetcher(
			settleInterval: 0.05,
			depthProvider: { 3 },
			prepare: { _, _, _ in },
			prune: { protected, queue in PlaybackCache.pruneIfNeeded(in: self.directory, protecting: protected, queueTrackIds: queue) }
		)
		prefetcher.queueChanged(queue: makeTracks(ids: [1, 2, 3]), currentIndex: 0)
		await Task.yield()

		XCTAssertTrue(FileManager.default.fileExists(atPath: libraryFile.path), "the offline library must be untouched")
	}

	/// The same depth and one-at-a-time rules, now eligible at High/Low too.
	func testHighQualityPrefetcherPreparesUpToTheDepth() async {
		var prepared: [Int] = []
		let prefetcher = PlaybackPrefetcher(
			settleInterval: 0.05,
			depthProvider: { 2 },
			shouldPrepare: { _ in
				PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: true)
			},
			isCached: { _ in false },
			prepare: { track, _, _ in prepared.append(track.id) }
		)

		prefetcher.queueChanged(queue: makeTracks(ids: [10, 20, 30, 40]), currentIndex: 0)
		await waitUntil { prepared.count == 2 }

		XCTAssertEqual(prepared, [20, 30])
	}

	// MARK: - Helpers

	/// Compile-time pin for the freeze fix: the heavy stream work must not be main-actor isolated,
	/// so every call below sits in a `nonisolated` context and annotating the function
	/// `@MainActor` again stops this file compiling. The download step is pinned by its
	/// conversion to a non-isolated `@Sendable` function value.
	nonisolated func testHeavyStreamWorkIsCallableOffTheMainActor() async throws {
		let directory = FileManager.default.temporaryDirectory
		let file = directory.appendingPathComponent("off-main-\(UUID().uuidString).m4a")

		_ = HLSStreaming.isPlayableMP4File(at: file)
		_ = PlaybackCache.usageBytes(in: directory)
		_ = PlaybackCache.cachedFile(forTrackId: 1, rung: .stereo(.max), in: directory)
		PlaybackCache.touch(file)
		PlaybackCache.pruneIfNeeded(in: directory)

		let download: @Sendable (URL, URL, @escaping HLSStreaming.ResourceFetcher) async throws -> Void = HLSStreaming.download
		_ = download
		let networkDownload: @Sendable (URL, URL, Bool, URLSession) async throws -> Void = Network.download
		_ = networkDownload
	}

	/// Without a fixed sleep that would make the test flaky.
	private func waitUntil(timeout: TimeInterval = 0.5, _ condition: () -> Bool) async {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return }
			try? await Task.sleep(for: .milliseconds(5))
		}
	}

	private func makeTracks(ids: [Int]) -> [Track] {
		ids.map { makeTrack(id: $0) }
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
