//
//  PlaybackCacheEvictionTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the cache eviction table: what survives (a protected track, the queue, the
/// prefetch window, a half-written download), what goes first (outside the queue, least
/// recently used), the tiebreak that frees the budget in fewer evictions, and the
/// hysteresis that stops a long queue pruning after every play.
final class PlaybackCacheEvictionTests: XCTestCase {
	private var directory: URL!

	override func setUp() {
		super.setUp()
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("PlaybackCacheEvictionTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: directory)
		directory = nil
		super.tearDown()
	}

	private func entry(_ name: String, size: Int, age: TimeInterval, now: Date) -> PlaybackCacheEviction.Entry {
		PlaybackCacheEviction.Entry(name: name, size: size, lastUsed: now.addingTimeInterval(-age))
	}

	private func evictions(
		_ entries: [PlaybackCacheEviction.Entry],
		protecting: Set<Int> = [],
		queue: Set<Int> = [],
		budget: Int,
		now: Date
	) -> [PlaybackCacheEviction.Entry] {
		PlaybackCacheEviction.evictions(
			entries: entries,
			protectedTrackIds: protecting,
			queueTrackIds: queue,
			limits: .init(budgetBytes: budget, maxAge: .greatestFiniteMagnitude, now: now)
		)
	}

	// MARK: - Protection

	func testAProtectedTrackIsNeverEvicted() {
		let now = Date()
		let entries = [
			entry("100-HI_RES_LOSSLESS.flac", size: 1000, age: 500, now: now),
			entry("200-HI_RES_LOSSLESS.flac", size: 1000, age: 100, now: now)
		]

		XCTAssertEqual(evictions(entries, protecting: [100], budget: 0, now: now).map(\.name), ["200-HI_RES_LOSSLESS.flac"])
	}

	func testAProtectedTrackSurvivesTheAgeSweep() {
		let now = Date()
		let entries = [
			entry("300-HI_RES_LOSSLESS.flac", size: 100, age: 8 * 24 * 60 * 60, now: now),
			entry("301-HI_RES_LOSSLESS.flac", size: 100, age: 8 * 24 * 60 * 60, now: now)
		]

		let evicted = PlaybackCacheEviction.evictions(
			entries: entries,
			protectedTrackIds: [300],
			queueTrackIds: [],
			limits: .init(budgetBytes: .max, maxAge: 7 * 24 * 60 * 60, now: now)
		)

		XCTAssertEqual(evicted.map(\.name), ["301-HI_RES_LOSSLESS.flac"])
	}

	/// A name without a track id is a half-written download or a file the cache does not
	/// own, so it is never touched.
	func testAFileWithoutATrackIdIsNeverEvicted() {
		let now = Date()
		let entries = [
			entry(".400-HI_RES_LOSSLESS.flac.tmp-ABCD", size: 1000, age: 9999, now: now),
			entry("401-HI_RES_LOSSLESS.flac", size: 1000, age: 100, now: now)
		]

		let evicted = PlaybackCacheEviction.evictions(
			entries: entries,
			protectedTrackIds: [],
			queueTrackIds: [],
			limits: .init(budgetBytes: 0, maxAge: 0, now: now)
		)

		XCTAssertEqual(evicted.map(\.name), ["401-HI_RES_LOSSLESS.flac"])
	}

	// MARK: - Order

	/// A track outside the queue goes before one inside it, even when the queued one is
	/// older, so the queue is the last thing the cache gives up.
	func testTracksOutsideTheQueueGoBeforeThoseInsideIt() {
		let now = Date()
		let entries = [
			entry("1-HI_RES_LOSSLESS.flac", size: 1000, age: 100, now: now),
			entry("2-HI_RES_LOSSLESS.flac", size: 1000, age: 500, now: now)
		]

		let evicted = evictions(entries, queue: [2], budget: 1500, now: now)

		XCTAssertEqual(evicted.map(\.name), ["1-HI_RES_LOSSLESS.flac"])
	}

	/// Within the same group the least recently used goes first.
	func testTheLeastRecentlyUsedGoesFirst() {
		let now = Date()
		let entries = [
			entry("10-HI_RES_LOSSLESS.flac", size: 1000, age: 100, now: now),
			entry("11-HI_RES_LOSSLESS.flac", size: 1000, age: 500, now: now)
		]

		let evicted = evictions(entries, budget: 1500, now: now)

		XCTAssertEqual(evicted.map(\.name), ["11-HI_RES_LOSSLESS.flac"])
	}

	/// Among equally old entries the larger goes first, which frees the budget in fewer
	/// evictions.
	func testEquallyOldEntriesEvictTheLargerFirst() {
		let now = Date()
		let entries = [
			entry("20-HI_RES_LOSSLESS.flac", size: 2000, age: 100, now: now),
			entry("21-HI_RES_LOSSLESS.flac", size: 500, age: 100, now: now)
		]

		let evicted = evictions(entries, budget: 2000, now: now)

		XCTAssertEqual(evicted.map(\.name), ["20-HI_RES_LOSSLESS.flac"])
	}

	// MARK: - Budget

	/// Over the limit, the cache is trimmed to 80% of it rather than to the limit, so a
	/// long queue does not prune after every play.
	func testGoingOverTheLimitTrimsToEightyPercent() {
		let now = Date()
		let entries = (0..<5).map { index in
			entry("\(30 + index)-HI_RES_LOSSLESS.flac", size: 1000, age: TimeInterval((5 - index) * 100), now: now)
		}

		let evicted = evictions(entries, budget: 4000, now: now)

		XCTAssertEqual(evicted.count, 2, "4000 above 5000 trims to 3200, so two 1000-byte files go")
		XCTAssertEqual(5000 - evicted.reduce(0) { $0 + $1.size }, 3000)
	}

	/// When the queue alone is over the budget the oldest in the queue go, so playback
	/// degrades rather than fails.
	func testABudgetSmallerThanTheQueueEvictsTheOldestInTheQueue() {
		let now = Date()
		let entries = [
			entry("40-HI_RES_LOSSLESS.flac", size: 1000, age: 300, now: now),
			entry("41-HI_RES_LOSSLESS.flac", size: 1000, age: 200, now: now),
			entry("42-HI_RES_LOSSLESS.flac", size: 1000, age: 100, now: now)
		]

		let evicted = evictions(entries, queue: [40, 41, 42], budget: 1500, now: now)

		XCTAssertEqual(evicted.map(\.name), ["40-HI_RES_LOSSLESS.flac", "41-HI_RES_LOSSLESS.flac"])
	}

	func testAnEmptyCacheEvictsNothing() {
		let evicted = PlaybackCacheEviction.evictions(
			entries: [],
			protectedTrackIds: [],
			queueTrackIds: [1],
			limits: .init(budgetBytes: 0, maxAge: 0, now: Date())
		)

		XCTAssertTrue(evicted.isEmpty)
	}

	func testACacheUnderTheBudgetIsLeftAlone() {
		let now = Date()
		let entries = [entry("50-HI_RES_LOSSLESS.flac", size: 1000, age: 0, now: now)]

		XCTAssertTrue(evictions(entries, budget: 2000, now: now).isEmpty)
	}

	func testCacheFileNamesYieldTheirTrackId() {
		XCTAssertEqual(PlaybackCacheEviction.trackId(of: "3000-HI_RES_LOSSLESS.m4a"), 3000)
		XCTAssertEqual(PlaybackCacheEviction.trackId(of: "300-HIGH.aac.m4a"), 300)
		XCTAssertNil(PlaybackCacheEviction.trackId(of: "no-id.flac"))
		XCTAssertNil(PlaybackCacheEviction.trackId(of: "300"))
	}

	// MARK: - Rule interactions

	/// Interaction: protection vs the 80% trim target. A protected file is not a candidate, so
	/// when the target cannot be reached without it the cache is left above the target rather
	/// than evicting the file. The failure this guards is evicting a file about to play to
	/// satisfy a number.
	func testProtectionBeatsTheTrimTarget() {
		let now = Date()
		let protected = entry("700-HI_RES_LOSSLESS.m4a", size: 1500, age: 400, now: now)
		let unprotected = entry("701-HI_RES_LOSSLESS.m4a", size: 1000, age: 100, now: now)

		let evicted = evictions([protected, unprotected], protecting: [700], budget: 1000, now: now)

		XCTAssertEqual(evicted.map(\.name), [unprotected.name], "only the unprotected file may go")
		let remaining = protected.size + unprotected.size - evicted.reduce(0) { $0 + $1.size }
		XCTAssertEqual(remaining, protected.size, "the protected file is all that is left")
		XCTAssertGreaterThan(
			remaining,
			Int(Double(1000) * PlaybackCacheEviction.trimFraction),
			"the cache stays above the trim target rather than evicting a protected file"
		)
		XCTAssertGreaterThan(remaining, 1000, "and above the budget, because nothing else may go")
	}

	/// Interaction: everything protected and over budget. No candidate exists, so nothing is
	/// evicted and the cache stays over budget instead of evicting something protected.
	func testEverythingProtectedEvictsNothingEvenOverBudget() {
		let now = Date()
		let entries = [
			entry("710-HI_RES_LOSSLESS.m4a", size: 1000, age: 500, now: now),
			entry("711-LOSSLESS.m4a", size: 1000, age: 100, now: now)
		]

		XCTAssertTrue(evictions(entries, protecting: [710, 711], budget: 500, now: now).isEmpty)
	}

	/// Interaction: non-queue vs queue vs protection in one decision. The oldest file is in the
	/// queue, yet the newer non-queue file goes first because the queue is the last thing the
	/// cache gives up; one eviction reaches the 80% target, so the walk stops there.
	func testNonQueueGoesBeforeQueueAndStopsAtTheTrimTarget() {
		let now = Date()
		let entries = [
			entry("720-HI_RES_LOSSLESS.m4a", size: 300, age: 1, now: now),
			entry("721-HI_RES_LOSSLESS.m4a", size: 600, age: 100, now: now),
			entry("722-HI_RES_LOSSLESS.m4a", size: 200, age: 500, now: now)
		]

		let evicted = evictions(entries, protecting: [720], queue: [722], budget: 1000, now: now)

		XCTAssertEqual(
			evicted.map(\.name),
			["721-HI_RES_LOSSLESS.m4a"],
			"the non-queue file goes, not the older queued one"
		)
		XCTAssertLessThanOrEqual(
			1100 - evicted.reduce(0) { $0 + $1.size },
			Int(Double(1000) * PlaybackCacheEviction.trimFraction),
			"one eviction reaches the trim target"
		)
	}

	/// Interaction: the queue alone exceeds the budget and part of it is protected. The
	/// protected queued file survives; the oldest unprotected queued files go.
	func testAProtectedQueuedFileSurvivesWhenTheQueueAloneExceedsTheBudget() {
		let now = Date()
		let entries = [
			entry("730-HI_RES_LOSSLESS.m4a", size: 600, age: 500, now: now),
			entry("731-HI_RES_LOSSLESS.m4a", size: 600, age: 300, now: now),
			entry("732-HI_RES_LOSSLESS.m4a", size: 600, age: 100, now: now)
		]

		let evicted = evictions(entries, protecting: [730], queue: [730, 731, 732], budget: 1000, now: now)

		XCTAssertEqual(evicted.map(\.name), ["731-HI_RES_LOSSLESS.m4a", "732-HI_RES_LOSSLESS.m4a"])
		XCTAssertEqual(1800 - evicted.reduce(0) { $0 + $1.size }, 600, "the protected queued file is all that is left")
	}

	/// Interaction: the age sweep runs before the trim, and the trim's budget test sees the
	/// post-sweep total. The stale file alone brings the cache under budget, so the fresh
	/// files are never touched; counting the swept file's size in the trim would delete them.
	///
	/// The stale file is deliberately small: it is the oldest entry, so a trim that ran
	/// first would reach its target by evicting it and then a fresh file, and the two
	/// inversions would show up as extra evictions.
	func testTheAgeSweepFreesTheBudgetBeforeTheTrimDecides() {
		let now = Date()
		let stale = entry("740-HI_RES_LOSSLESS.m4a", size: 1000, age: 8 * 24 * 60 * 60, now: now)
		let freshA = entry("741-HI_RES_LOSSLESS.m4a", size: 5000, age: 100, now: now)
		let freshB = entry("742-HI_RES_LOSSLESS.m4a", size: 5000, age: 50, now: now)

		let evicted = PlaybackCacheEviction.evictions(
			entries: [stale, freshA, freshB],
			protectedTrackIds: [],
			queueTrackIds: [],
			limits: .init(budgetBytes: 10000, maxAge: 7 * 24 * 60 * 60, now: now)
		)

		XCTAssertEqual(
			evicted.map(\.name),
			[stale.name],
			"the sweep alone frees the budget, so the trim evicts nothing"
		)
	}

	/// Interaction: the size tiebreak inside the non-queue group, with a larger protected
	/// non-queue file among the entries. Equal ages make the larger unprotected file go first;
	/// the larger protected file stays, because protection outweighs the tiebreak.
	func testSizeTiebreakEvictsTheLargerUnprotectedFileAndSparesTheLargerProtectedOne() {
		let now = Date()
		let protectedLarger = entry("750-HI_RES_LOSSLESS.m4a", size: 1000, age: 100, now: now)
		let unprotectedLarger = entry("751-HI_RES_LOSSLESS.m4a", size: 800, age: 100, now: now)
		let unprotectedSmaller = entry("752-HI_RES_LOSSLESS.m4a", size: 300, age: 100, now: now)

		let evicted = evictions(
			[protectedLarger, unprotectedLarger, unprotectedSmaller],
			protecting: [750],
			budget: 1750,
			now: now
		)

		XCTAssertEqual(
			evicted.map(\.name),
			["751-HI_RES_LOSSLESS.m4a"],
			"the larger unprotected file goes, and one eviction reaches the target"
		)
	}

	/// Interaction: one track, several qualities. Protection is per track id, so every quality
	/// of the protected track survives while the unprotected tracks' files are candidates.
	func testProtectionCoversEveryQualityOfTheTrack() {
		let now = Date()
		let entries = [
			entry("760-HI_RES_LOSSLESS.m4a", size: 500, age: 400, now: now),
			entry("760-LOSSLESS.m4a", size: 500, age: 300, now: now),
			entry("761-HI_RES_LOSSLESS.m4a", size: 500, age: 200, now: now),
			entry("762-HI_RES_LOSSLESS.m4a", size: 500, age: 100, now: now)
		]

		let evicted = evictions(entries, protecting: [760], budget: 1500, now: now)

		XCTAssertEqual(evicted.map(\.name), ["761-HI_RES_LOSSLESS.m4a", "762-HI_RES_LOSSLESS.m4a"])
		XCTAssertFalse(evicted.contains { $0.name.hasPrefix("760-") }, "every quality of the protected track survives")
	}

	/// Interaction: one track, several qualities (cont.). Eviction is per file, not per track:
	/// an unprotected track's files may go one at a time. Here one eviction reaches the
	/// target, so only the older file of the unprotected track goes and the newer stays.
	func testAnUnprotectedTracksFilesAreIndependentCandidates() {
		let now = Date()
		let entries = [
			entry("770-HI_RES_LOSSLESS.m4a", size: 500, age: 400, now: now),
			entry("770-LOSSLESS.m4a", size: 500, age: 300, now: now),
			entry("771-HI_RES_LOSSLESS.m4a", size: 500, age: 200, now: now),
			entry("771-LOSSLESS.m4a", size: 500, age: 100, now: now)
		]

		let evicted = evictions(entries, protecting: [770], budget: 1900, now: now)

		XCTAssertEqual(
			evicted.map(\.name),
			["771-HI_RES_LOSSLESS.m4a"],
			"one file of the unprotected track can go without the other"
		)
	}

	/// Interaction: one track, several qualities (cont.). With a tighter budget both files of
	/// an unprotected track go, so an unprotected id gets no per-track exemption either.
	func testBothFilesOfAnUnprotectedTrackCanGo() {
		let now = Date()
		let entries = [
			entry("780-HI_RES_LOSSLESS.m4a", size: 500, age: 400, now: now),
			entry("780-LOSSLESS.m4a", size: 500, age: 300, now: now),
			entry("781-HI_RES_LOSSLESS.m4a", size: 500, age: 100, now: now)
		]

		let evicted = evictions(entries, protecting: [781], budget: 1000, now: now)

		XCTAssertEqual(
			evicted.map(\.name),
			["780-HI_RES_LOSSLESS.m4a", "780-LOSSLESS.m4a"],
			"both qualities of the unprotected track go"
		)
	}

	/// Interaction: an empty queue, a protected set and an over-budget cache. With no queue
	/// there is no group split, so the plain least-recently-used among the rest goes, and the
	/// protected file is untouched.
	func testEmptyQueueWithProtectionFallsBackToPlainLeastRecentlyUsed() {
		let now = Date()
		let protected = entry("790-HI_RES_LOSSLESS.m4a", size: 600, age: 1, now: now)
		let older = entry("791-HI_RES_LOSSLESS.m4a", size: 700, age: 500, now: now)
		let newer = entry("792-HI_RES_LOSSLESS.m4a", size: 100, age: 100, now: now)

		let evicted = evictions([protected, older, newer], protecting: [790], queue: [], budget: 1000, now: now)

		XCTAssertEqual(evicted.map(\.name), [older.name], "the least recently used unprotected file goes")
	}

	// MARK: - Boundary

	/// The guard that keeps the developer's downloads out of reach: an evicting prune
	/// deletes inside the playback cache directory and must leave a file in a separate
	/// offline-style directory — with an old modification date, so the age sweep would
	/// take it if it were ever seen — untouched.
	func testPruneDeletesOnlyInsideThePlaybackCacheDirectoryAndNotTheOfflineLibrary() throws {
		let now = Date()
		let library = FileManager.default.temporaryDirectory
			.appendingPathComponent("PlaybackCacheEvictionTests-offline-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: library) }
		let outside = library.appendingPathComponent("999-lossless.flac")
		try Data(repeating: 7, count: 2000).write(to: outside)
		try FileManager.default.setAttributes(
			[.modificationDate: now.addingTimeInterval(-30 * 24 * 60 * 60)],
			ofItemAtPath: outside.path
		)
		let inside = directory.appendingPathComponent("888-HI_RES_LOSSLESS.m4a")
		try Data(repeating: 1, count: 2000).write(to: inside)

		let removed = PlaybackCache.prune(in: directory, maxBytes: 0, maxAge: 0, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), ["888-HI_RES_LOSSLESS.m4a"], "the prune must delete inside the cache")
		XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))
		XCTAssertTrue(
			FileManager.default.fileExists(atPath: outside.path),
			"the prune must never leave the playback cache directory"
		)
	}
}
