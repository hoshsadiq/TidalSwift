//
//  HiResStreamCacheTests.swift
//  TidalSwiftLibTests
//

import AVFoundation
import XCTest
@testable import TidalSwiftLib

/// Pins the playback cache and the prefetcher: the cache stays bounded, LRU evicts the
/// oldest while sparing the prefetch window, the prefetch window follows the queue, and
/// the browsing guard stops then resumes preparing. Everything runs in a temporary
/// directory, never the real caches, and never the offline library.
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

	/// Real FLAC bytes, so a cache file passes the completeness check the cache applies
	/// before trusting a file. A handful of arbitrary bytes is exactly what the check
	/// is meant to reject.
	private func silentFLACBytes() throws -> Data {
		try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "flac", subdirectory: "Fixtures")))
	}

	// MARK: - Pruning

	/// Size cap: the least recently used entries go first until the directory is under
	/// the cap.
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

	/// A file inside the prefetch window (or the track currently playing) is exempt
	/// from eviction: removing a file prepared for playback would make the prefetch
	/// pointless.
	func testProtectedTrackIsNeverEvicted() throws {
		let now = Date()
		let oldest = try write("100-HI_RES_LOSSLESS.flac", bytes: 1000, modified: now.addingTimeInterval(-300))
		let newer = try write("200-HI_RES_LOSSLESS.flac", bytes: 1000, modified: now.addingTimeInterval(-100))

		let removed = HiResStreamCache.prune(in: directory, maxBytes: 0, maxAge: .greatestFiniteMagnitude, protecting: [100], now: now)

		XCTAssertFalse(removed.map(\.lastPathComponent).contains(oldest.lastPathComponent))
		XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path), "protected track must survive the size cap")
		XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
	}

	/// The protection also survives the age cap, so the window is not aged out from
	/// under the player.
	func testProtectedTrackSurvivesTheAgeCap() throws {
		let now = Date()
		let old = try write("300-HI_RES_LOSSLESS.flac", bytes: 100, modified: now.addingTimeInterval(-8 * 24 * 60 * 60))

		let removed = HiResStreamCache.prune(in: directory, maxBytes: .max, maxAge: 7 * 24 * 60 * 60, protecting: [300], now: now)

		XCTAssertTrue(removed.isEmpty)
		XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
	}

	// MARK: - Unified budget

	/// A DASH file and a hi-res file both count toward the one budget the settings
	/// screen shows.
	func testDashAndHiResFilesShareOneBudget() throws {
		_ = try write("600.aac.m4a", bytes: 1500, modified: Date())
		_ = try write("601.flac", bytes: 500, modified: Date())

		XCTAssertEqual(HiResStreamCache.usageBytes(in: directory), 2000)
	}

	/// Eviction takes the oldest file whichever kind it is, not one lane's files before
	/// the other's.
	func testEvictionTakesTheOldestFileOfEitherKind() throws {
		let now = Date()
		let oldDash = try write("700.aac.m4a", bytes: 1000, modified: now.addingTimeInterval(-300))
		let newHiRes = try write("701.flac", bytes: 1000, modified: now.addingTimeInterval(-100))

		let removed = HiResStreamCache.prune(in: directory, maxBytes: 1500, maxAge: .greatestFiniteMagnitude, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), [oldDash.lastPathComponent])
		XCTAssertFalse(FileManager.default.fileExists(atPath: oldDash.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: newHiRes.path))
	}

	/// A DASH file belonging to a track inside the prefetch window is spared by the same
	/// exemption a hi-res file gets.
	func testProtectedDashFileSurvivesTheSizeCap() throws {
		let now = Date()
		let oldestDash = try write("800-HIGH.aac.m4a", bytes: 1000, modified: now.addingTimeInterval(-300))
		let newerHiRes = try write("801-HI_RES_LOSSLESS.flac", bytes: 1000, modified: now.addingTimeInterval(-100))

		let removed = HiResStreamCache.prune(in: directory, maxBytes: 0, maxAge: .greatestFiniteMagnitude, protecting: [800], now: now)

		XCTAssertFalse(removed.map(\.lastPathComponent).contains(oldestDash.lastPathComponent))
		XCTAssertTrue(FileManager.default.fileExists(atPath: oldestDash.path), "the DASH file inside the window must survive")
		XCTAssertFalse(FileManager.default.fileExists(atPath: newerHiRes.path))
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

	/// Usage counts the bytes in the cache directory, which is what the settings screen
	/// shows.
	func testUsageCountsCacheBytes() throws {
		_ = try write("400.flac", bytes: 1500, modified: Date())
		_ = try write("500.flac", bytes: 500, modified: Date())

		XCTAssertEqual(HiResStreamCache.usageBytes(in: directory), 2000)
	}

	/// A file already in the cache is handed back as the stream, so a replay does not
	/// download and decrypt again. The session has no reachable network, so a download
	/// attempt would fail: returning the cached file is the only way this passes.
	func testCachedFileIsReusedWithoutDownloading() async throws {
		let trackId = 779_500_001
		let cached = directory.appendingPathComponent("\(trackId)-HI_RES_LOSSLESS.flac")
		try silentFLACBytes().write(to: cached)

		let offlineLibrary = TemporaryOfflineLibrary(label: "HiResStreamCache")
		defer { offlineLibrary.remove() }
		let session = offlineLibrary.makeSession(config: Config(
			accessToken: try Self.tokenWithCukClaim(),
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: .high
		))

		let playback = await HiResStreaming.playbackFile(
			for: makeTrack(id: trackId),
			session: session,
			quality: .max,
			cacheDirectory: directory
		)

		XCTAssertEqual(playback?.url, cached)
	}

	// MARK: - Quality in the cache key

	/// A track's two tiers are two different files: the name carries the quality, and a
	/// file cached at one tier is never served at another. Without the quality in the
	/// name, a Max play followed by a Lossless play reuses the 24-bit file (and the
	/// badge claims the wrong format).
	func testCacheKeysDifferPerQualityAndDoNotServeTheOtherTier() async throws {
		let trackId = 779_500_002
		let maxFile = directory.appendingPathComponent("\(trackId)-HI_RES_LOSSLESS.flac")
		try silentFLACBytes().write(to: maxFile)

		XCTAssertNotEqual(
			HiResStreamCache.fileURL(forTrackId: trackId, quality: .max, in: directory),
			HiResStreamCache.fileURL(forTrackId: trackId, quality: .high, in: directory),
			"the cached file name must carry the quality"
		)
		XCTAssertNotEqual(
			HiResStreamCache.dashFileURL(forTrackId: trackId, quality: .medium, in: directory),
			HiResStreamCache.dashFileURL(forTrackId: trackId, quality: .low, in: directory),
			"the DASH file name must carry the quality too"
		)

		let offlineLibrary = TemporaryOfflineLibrary(label: "HiResStreamCache")
		defer { offlineLibrary.remove() }
		let session = offlineLibrary.makeSession(config: Config(
			accessToken: try Self.tokenWithCukClaim(),
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: .max
		))

		let atMax = await HiResStreaming.playbackFile(
			for: makeTrack(id: trackId), session: session, quality: .max, cacheDirectory: directory
		)
		XCTAssertEqual(atMax?.url, maxFile, "the Max file must be served at Max")

		// No network is reachable, so a Lossless file that is not in the cache can only
		// come back nil — it must not fall back to the Max file on disk.
		let atLossless = await HiResStreaming.playbackFile(
			for: makeTrack(id: trackId), session: session, quality: .high, cacheDirectory: directory
		)
		XCTAssertNil(atLossless, "a file cached at Max must not be served at Lossless")
	}

	// MARK: - Completeness

	/// A cache hit is existence-only no longer: a stub left by an interrupted download
	/// is deleted and reported as a miss, so the next play re-downloads instead of
	/// serving a truncated file forever.
	func testTruncatedCachedFileIsDeletedAndTreatedAsAMiss() throws {
		let url = directory.appendingPathComponent("779500003-HI_RES_LOSSLESS.flac")
		// The right signature, but far too short to be a track.
		try Data("fLaC".utf8).write(to: url)

		XCTAssertNil(HiResStreamCache.cachedFile(forTrackId: 779_500_003, quality: .max, in: directory))
		XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the stub must be deleted")
	}

	/// A file that does not start with the FLAC signature was not written by this app's
	/// decrypt; it is deleted rather than handed to the player.
	func testCachedFileWithoutTheFlacSignatureIsDeleted() throws {
		let url = directory.appendingPathComponent("779500004-HI_RES_LOSSLESS.flac")
		try Data(repeating: 0x41, count: 4096).write(to: url)

		XCTAssertNil(HiResStreamCache.cachedFile(forTrackId: 779_500_004, quality: .max, in: directory))
		XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a file without the signature must be deleted")
	}

	/// A complete FLAC file is still trusted, so the check does not throw away real
	/// cache entries.
	func testCompleteCachedFileIsStillServed() throws {
		let url = directory.appendingPathComponent("779500005-HI_RES_LOSSLESS.flac")
		try silentFLACBytes().write(to: url)

		XCTAssertEqual(HiResStreamCache.cachedFile(forTrackId: 779_500_005, quality: .max, in: directory), url)
	}

	/// The DASH cache applies the same rule with its own format's signature: an
	/// assembled `.m4a` is trusted, while a stub or a file without the MP4 `ftyp` box is
	/// deleted and treated as a miss.
	func testDashCacheValidatesItsOwnSignatureAndLength() throws {
		let trackId = 779_500_006
		let complete = HiResStreamCache.dashFileURL(forTrackId: trackId, quality: .medium, in: directory)
		try (Data([0, 0, 0, 0x20]) + Data("ftyp".utf8) + Data(repeating: 0, count: 4096)).write(to: complete)
		XCTAssertEqual(HiResStreamCache.cachedDashFile(forTrackId: trackId, quality: .medium, in: directory), complete)

		let stub = HiResStreamCache.dashFileURL(forTrackId: trackId + 1, quality: .medium, in: directory)
		try Data([0, 0, 0, 0x20]).write(to: stub)
		XCTAssertNil(HiResStreamCache.cachedDashFile(forTrackId: trackId + 1, quality: .medium, in: directory))
		XCTAssertFalse(FileManager.default.fileExists(atPath: stub.path), "the stub must be deleted")

		let wrongMagic = HiResStreamCache.dashFileURL(forTrackId: trackId + 2, quality: .medium, in: directory)
		try Data(repeating: 0x41, count: 4096).write(to: wrongMagic)
		XCTAssertNil(HiResStreamCache.cachedDashFile(forTrackId: trackId + 2, quality: .medium, in: directory))
		XCTAssertFalse(FileManager.default.fileExists(atPath: wrongMagic.path), "a file without the signature must be deleted")
	}

	// MARK: - De-duplication

	/// Concurrent preparation of the same track and quality runs the work once and both
	/// callers get the result. The prefetcher and a play that arrives meanwhile share this
	/// table, so the manifest and every segment are fetched once, not twice.
	func testConcurrentPreparationOfTheSameTrackRunsTheWorkOnce() async throws {
		let trackId = 779_600_001
		let dir = try XCTUnwrap(directory)
		let produced = dir.appendingPathComponent("deduplicated.m4a")
		let runs = RunCounter()
		let operation: @Sendable () async -> URL? = {
			await runs.increment()
			try? await Task.sleep(for: .milliseconds(50))
			try? Data("assembled".utf8).write(to: produced)
			return produced
		}

		async let first = HiResStreamPreparation.preparedFile(for: trackId, quality: .medium, in: dir, operation: operation)
		async let second = HiResStreamPreparation.preparedFile(for: trackId, quality: .medium, in: dir, operation: operation)
		let (firstURL, secondURL) = await (first, second)
		let runCount = await runs.value

		XCTAssertEqual(runCount, 1, "two concurrent preparations of one track must run the work once")
		XCTAssertEqual(firstURL, produced)
		XCTAssertEqual(secondURL, produced)
	}

	/// A different quality is different work: the key carries the quality, so a Max
	/// preparation does not borrow the Medium task's result.
	func testPreparationKeySeparatesQualities() async throws {
		let trackId = 779_600_002
		let dir = try XCTUnwrap(directory)
		let runs = RunCounter()
		let operation: @Sendable () async -> URL? = {
			let count = await runs.increment()
			return dir.appendingPathComponent("quality-\(count).m4a")
		}

		async let medium = HiResStreamPreparation.preparedFile(for: trackId, quality: .medium, in: dir, operation: operation)
		async let low = HiResStreamPreparation.preparedFile(for: trackId, quality: .low, in: dir, operation: operation)
		_ = await (medium, low)
		let runCount = await runs.value

		XCTAssertEqual(runCount, 2, "the quality must be part of the in-flight key")
	}

	private actor RunCounter {
		private(set) var value = 0
		@discardableResult func increment() -> Int {
			value += 1
			return value
		}
	}

	// MARK: - Bit depth

	/// The persisted manifest values describe the file, so `describe` reports them even
	/// though the FLAC file itself cannot: `AVAudioFile` reads 0 bits per channel for one.
	func testBitDepthComesFromPersistedMetadataWhenTheFileCannotReportIt() throws {
		let url = directory.appendingPathComponent("950-HI_RES_LOSSLESS.flac")
		try Data("not a real flac".utf8).write(to: url)
		HiResStreamCache.writeFormatMetadata(bitDepth: 24, sampleRate: 44_100, for: url)

		let playback = HiResStreaming.describe(url)

		XCTAssertEqual(playback.bitDepth, 24)
		XCTAssertEqual(playback.sampleRate, 44_100)
	}

	/// With no persisted values the file is the fallback, and a file that carries a
	/// format reports it.
	func testBitDepthComesFromTheFileWhenItCarriesOne() throws {
		let url = directory.appendingPathComponent("951-16bit.wav")
		let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: true))
		let writer = try AVAudioFile(forWriting: url, settings: format.settings)
		// The buffer must match the file's processing format, which is not necessarily
		// the on-disk one for a WAV.
		let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 100))
		buffer.frameLength = 100
		try writer.write(from: buffer)

		let playback = HiResStreaming.describe(url)

		XCTAssertEqual(playback.bitDepth, 16)
		XCTAssertEqual(playback.sampleRate, 44_100)
	}

	/// Neither a persisted value nor a readable file means the depth is unknown, and the
	/// badge reports none rather than guessing from the requested quality.
	func testBitDepthIsNilWhenNothingReportsOne() throws {
		let url = directory.appendingPathComponent("952-HI_RES_LOSSLESS.flac")
		try Data("garbage that AVAudioFile cannot open".utf8).write(to: url)

		let playback = HiResStreaming.describe(url)

		XCTAssertNil(playback.bitDepth)
		XCTAssertNil(playback.sampleRate)
	}

	// MARK: - Prefetch window

	/// The window is the tracks after the current one, in queue order, and never wraps.
	func testPrefetchWindowFollowsQueueOrder() {
		let queue = makeTracks(ids: [10, 20, 30, 40, 50])

		XCTAssertEqual(
			HiResPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 3).map(\.id),
			[20, 30, 40]
		)
		XCTAssertEqual(
			HiResPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 2, depth: 3).map(\.id),
			[40, 50]
		)
	}

	/// The depth setting is respected, including 0 (off).
	func testPrefetchDepthIsRespected() {
		let queue = makeTracks(ids: [10, 20, 30, 40, 50])

		XCTAssertTrue(HiResPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 0).isEmpty)
		XCTAssertEqual(
			HiResPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 2).map(\.id),
			[20, 30]
		)
		XCTAssertEqual(
			HiResPrefetchPolicy.upcomingTracks(queue: queue, currentIndex: 0, depth: 15).map(\.id),
			[20, 30, 40, 50]
		)
	}

	/// Tracks already in the cache, and tracks the settings would not play through the
	/// hi-res route, are left out of the window.
	func testWindowSkipsCachedAndIneligibleTracks() {
		let queue = makeTracks(ids: [10, 20, 30, 40])

		let window = HiResPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: 0,
			depth: 3,
			shouldPrepare: { $0.id != 30 },
			isCached: { $0.id == 20 }
		)

		XCTAssertEqual(window.map(\.id), [40])
	}

	/// Eligibility follows the same route rule as playback: at High/Low a stereo track
	/// leads with DASH, so its upcoming tracks are prepared.
	func testHighQualityQueuePreparesItsUpcomingTracks() {
		let queue = makeTracks(ids: [10, 20, 30, 40])

		let window = HiResPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: 0,
			depth: 2,
			shouldPrepare: { track in
				HiResStreamingPolicy.usesLocalFile(
					sessionHasHiResStereoAccess: true,
					preferDolbyAtmos: false,
					trackHasStereo: track.hasStereo,
					trackHasDolbyAtmos: track.hasDolbyAtmos,
					quality: .medium
				)
			}
		)

		XCTAssertEqual(window.map(\.id), [20, 30])
	}

	/// At Lossless Tidal's route leads too, so the upcoming tracks are prepared — the
	/// prepared cache is what keeps that uniform choice instant at playback time.
	func testLosslessStereoQueuePreparesItsUpcomingTracks() {
		let queue = makeTracks(ids: [10, 20, 30])

		let window = HiResPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: 0,
			depth: 3,
			shouldPrepare: { track in
				HiResStreamingPolicy.usesLocalFile(
					sessionHasHiResStereoAccess: true,
					preferDolbyAtmos: false,
					trackHasStereo: track.hasStereo,
					trackHasDolbyAtmos: track.hasDolbyAtmos,
					quality: .high
				)
			}
		)

		XCTAssertEqual(window.map(\.id), [20, 30])
	}

	/// With the toggle off nothing is prepared at any tier: the direct-stream path
	/// streams, so there is no local file to fetch ahead of time.

	// MARK: - Prefetch behaviour

	/// Three skips in a row stop preparing until a track settles, then preparing
	/// resumes with the window at the new current track.
	func testThreeSkipsStopPreparingAndSettlingResumesIt() async {
		var prepared: [Int] = []
		let prefetcher = HiResStreamPrefetcher(
			settleInterval: 0.2,
			depthProvider: { 2 },
			shouldPrepare: { _ in true },
			isCached: { _ in false },
			prepare: { prepared.append($0.id) }
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

	/// Fewer than three skips do not stop preparing.
	func testTwoSkipsDoNotStopPreparing() async {
		var prepared: [Int] = []
		let prefetcher = HiResStreamPrefetcher(
			settleInterval: 0.05,
			depthProvider: { 1 },
			prepare: { prepared.append($0.id) }
		)
		let queue = makeTracks(ids: [10, 20, 30])

		prefetcher.trackSkipped()
		prefetcher.trackSkipped()
		XCTAssertFalse(prefetcher.isPausedForBrowsing)

		prefetcher.queueChanged(queue: queue, currentIndex: 0)
		await waitUntil { prepared.count == 1 }
		XCTAssertEqual(prepared, [20])
	}

	/// Preparing and pruning never reach into the offline library.
	func testPrefetchAndPruneStayOutOfTheOfflineLibrary() async {
		let offlineLibrary = FileManager.default.temporaryDirectory
			.appendingPathComponent("HiResStreamCacheTests-library-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: offlineLibrary, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: offlineLibrary) }
		let libraryFile = offlineLibrary.appendingPathComponent("123.lossless.flac")
		try? Data(repeating: 3, count: 1000).write(to: libraryFile)

		let prefetcher = HiResStreamPrefetcher(
			settleInterval: 0.05,
			depthProvider: { 3 },
			prepare: { _ in },
			prune: { protected in HiResStreamCache.pruneIfNeeded(in: self.directory, protecting: protected) }
		)
		prefetcher.queueChanged(queue: makeTracks(ids: [1, 2, 3]), currentIndex: 0)
		await Task.yield()

		XCTAssertTrue(FileManager.default.fileExists(atPath: libraryFile.path), "the offline library must be untouched")
	}

	/// A High-quality queue is prepared one at a time, up to the depth: the same depth
	/// and one-at-a-time rules, now eligible at High/Low too.
	func testHighQualityPrefetcherPreparesUpToTheDepth() async {
		var prepared: [Int] = []
		let prefetcher = HiResStreamPrefetcher(
			settleInterval: 0.05,
			depthProvider: { 2 },
			shouldPrepare: { track in
				HiResStreamingPolicy.usesLocalFile(
					sessionHasHiResStereoAccess: true,
					preferDolbyAtmos: false,
					trackHasStereo: track.hasStereo,
					trackHasDolbyAtmos: track.hasDolbyAtmos,
					quality: .medium
				)
			},
			isCached: { _ in false },
			prepare: { prepared.append($0.id) }
		)

		prefetcher.queueChanged(queue: makeTracks(ids: [10, 20, 30, 40]), currentIndex: 0)
		await waitUntil { prepared.count == 2 }

		XCTAssertEqual(prepared, [20, 30])
	}

	// MARK: - Helpers

	/// Compile-time pin for the freeze fix: the heavy stream work must not be
	/// main-actor isolated. Every call below is in a `nonisolated` context, so if the
	/// function is annotated `@MainActor` again this file stops compiling — a
	/// regression guard no comment can match. The download+decrypt step is pinned by
	/// its conversion to a non-isolated `@Sendable` function value, which a
	/// main-actor function cannot satisfy.
	nonisolated func testHeavyStreamWorkIsCallableOffTheMainActor() async throws {
		let directory = FileManager.default.temporaryDirectory
		let file = directory.appendingPathComponent("off-main-\(UUID().uuidString).flac")

		_ = HiResStreaming.describe(file)
		_ = HiResStreamCache.readFormatMetadata(for: file)
		_ = HiResStreamCache.usageBytes(in: directory)
		_ = HiResStreamCache.cachedFile(forTrackId: 1, quality: .max, in: directory)
		HiResStreamCache.touch(file)
		HiResStreamCache.pruneIfNeeded(in: directory)

		let downloadAndDecrypt: @Sendable (AcceptedHiResManifest, URL) async throws -> Void = HiResStreaming.downloadAndDecrypt
		_ = downloadAndDecrypt
	}

	/// Waits for a condition the prefetcher sets on the main actor, without a fixed
	/// sleep that would make the test flaky.
	private func waitUntil(timeout: TimeInterval = 0.5, _ condition: () -> Bool) async {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return }
			try? await Task.sleep(for: .milliseconds(5))
		}
	}

	private static func tokenWithCukClaim() throws -> String {
		let payload: [String: Any] = ["uid": 1, "cuk": "client-key"]
		let data = try JSONSerialization.data(withJSONObject: payload)
		let body = data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return "Bearer .\(body).signature"
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
