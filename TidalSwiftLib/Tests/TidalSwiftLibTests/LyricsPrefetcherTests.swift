//
//  LyricsPrefetcherTests.swift
//  TidalSwiftLibTests
//

import Foundation
import XCTest
@testable import TidalSwiftLib

/// The fetch belongs to the track rather than to a panel, so these pin what a shared fetch has
/// to get right: one chain per track, the schedule, the cap, and a failure that is not
/// remembered.
@MainActor
final class LyricsPrefetcherTests: XCTestCase {
	private let tidalLyrics = TidalLyrics(lrc: "[00:01.00]line", plain: "line")

	/// Counts calls from a fetch closure, which cannot capture a mutable local once it is
	/// handed to another task.
	private actor CallCounter {
		private(set) var value = 0

		func record() {
			value += 1
		}
	}

	private func assertFound(_ outcome: LyricsOutcome<LyricsResult>, _ message: String) {
		guard case .found(let result) = outcome else {
			return XCTFail("\(message): got \(outcome)")
		}
		XCTAssertEqual(result.source, .tidal, message)
		XCTAssertEqual(result.lines.map(\.text), ["line"], message)
	}

	private func query(_ trackId: Int) -> LyricsQuery {
		LyricsQuery(trackId: trackId, title: "Title", artistName: "Artist", albumName: "Album", duration: 200)
	}

	/// Milliseconds instead of seconds, so the schedule's shape is tested without the waits.
	private let fastSchedule = LyricsPrefetcher.Schedule(
		delays: [.milliseconds(1), .milliseconds(2), .milliseconds(3)],
		totalBudget: .seconds(2)
	)

	/// A resolver whose only useful answer comes from the injected fetchers, with no caches that
	/// could hide the call count.
	private func makePrefetcher(
		tidal: @escaping LyricsResolver.TidalFetcher,
		lrclib: @escaping LyricsResolver.LRCLIBFetcher = { _, _, _, _ in .notFound },
		schedule: LyricsPrefetcher.Schedule? = nil
	) -> LyricsPrefetcher {
		LyricsPrefetcher(
			resolver: LyricsResolver(
				tidalFetcher: tidal,
				lrclibFetcher: lrclib,
				cache: LyricsCache()
			),
			schedule: schedule ?? fastSchedule
		)
	}

	func testTheAppsScheduleIsThePolicyMany() {
		// One place holds the real numbers; this pins that the prefetcher does not drift from it.
		XCTAssertEqual(LyricsPrefetcher.Schedule.standard.delays, LyricsRetryPolicy.delays)
		XCTAssertEqual(LyricsPrefetcher.Schedule.standard.totalBudget, LyricsRetryPolicy.totalBudget)
	}

	func testAFailureIsRetriedOnTheScheduleThenStops() async {
		var calls = 0
		let prefetcher = makePrefetcher(tidal: { _ in
			calls += 1
			return .failed
		})

		let outcome = await prefetcher.lyrics(for: query(1), preferLRCLIB: false)

		XCTAssertEqual(outcome, .failed)
		XCTAssertEqual(calls, fastSchedule.delays.count + 1, "the first try plus three automatic ones")
	}

	func testAResultEndsTheSchedule() async {
		var calls = 0
		let prefetcher = makePrefetcher(tidal: { _ in
			calls += 1
			return .found(self.tidalLyrics)
		})

		let outcome = await prefetcher.lyrics(for: query(2), preferLRCLIB: false)

		assertFound(outcome, "a result ends the schedule")
		XCTAssertEqual(calls, 1)
	}

	func testAMissIsNeverRetried() async {
		var calls = 0
		let prefetcher = makePrefetcher(tidal: { _ in
			calls += 1
			return .notFound
		})

		let outcome = await prefetcher.lyrics(for: query(3), preferLRCLIB: false)

		XCTAssertEqual(outcome, .notFound)
		XCTAssertEqual(calls, 1)
	}

	func testTwoAsksForOneTrackShareOneFetch() async {
		// The drawer and the miniplayer on the same track must not run two chains.
		let counter = CallCounter()
		let prefetcher = makePrefetcher(tidal: { _ in
			await counter.record()
			try? await Task.sleep(for: .milliseconds(200))
			return .found(self.tidalLyrics)
		})

		let read = query(4)
		async let first = prefetcher.lyrics(for: read, preferLRCLIB: false)
		try? await Task.sleep(for: .milliseconds(50))
		async let second = prefetcher.lyrics(for: read, preferLRCLIB: false)
		let outcomes = await [first, second]

		for outcome in outcomes {
			assertFound(outcome, "both asks see the result")
		}
		let calls = await counter.value
		XCTAssertEqual(calls, 1, "the second ask joins the first")
	}

	func testAWarmFetchServesALaterRead() async {
		var calls = 0
		let prefetcher = makePrefetcher(tidal: { _ in
			calls += 1
			return .found(self.tidalLyrics)
		})

		prefetcher.prepare(for: query(5), preferLRCLIB: false)
		// The prepare is fire-and-forget, so wait for it the way a later read would.
		let outcome = await prefetcher.lyrics(for: query(5), preferLRCLIB: false)

		assertFound(outcome, "a result ends the schedule")
		XCTAssertEqual(calls, 1, "a warmed track is not fetched again by the read")
	}

	func testASpentScheduleIsNotRememberedAsAnAnswer() async {
		var calls = 0
		let prefetcher = makePrefetcher(tidal: { _ in
			calls += 1
			return .failed
		})

		_ = await prefetcher.lyrics(for: query(6), preferLRCLIB: false)
		let firstRound = calls
		_ = await prefetcher.lyrics(for: query(6), preferLRCLIB: false)

		XCTAssertEqual(calls, firstRound * 2, "the retry button gets a fresh schedule, not a remembered failure")
	}

	func testTheCapStopsAHangingProvider() async {
		let prefetcher = makePrefetcher(
			tidal: { _ in
				// Far longer than the cap, standing in for a provider that never answers.
				try? await Task.sleep(for: .seconds(120))
				return .found(self.tidalLyrics)
			},
			schedule: LyricsPrefetcher.Schedule(delays: [.milliseconds(1)], totalBudget: .milliseconds(100))
		)

		let start = ContinuousClock.now
		let outcome = await prefetcher.lyrics(for: query(7), preferLRCLIB: false)

		XCTAssertEqual(outcome, .failed)
		XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "the cap cancels the attempt in flight")
	}
}
