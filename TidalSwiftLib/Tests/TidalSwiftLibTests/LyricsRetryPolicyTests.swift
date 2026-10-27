//
//  LyricsRetryPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the automatic retry schedule: the delays, the three retries, and the
/// two outcomes that must never be retried.
final class LyricsRetryPolicyTests: XCTestCase {
	private let result = LyricsResult(lines: [LyricLine(time: 1, text: "line")], plainText: nil, source: .tidal)

	private func delay(after completedTries: Int, _ outcome: LyricsOutcome<LyricsResult>) -> Duration? {
		LyricsRetryPolicy.retryDelay(afterCompletedTries: completedTries, outcome: outcome)
	}

	func testDelaysAreOneThreeAndEightSeconds() {
		XCTAssertEqual(LyricsRetryPolicy.delays, [.seconds(1), .seconds(3), .seconds(8)])
	}

	func testThreeRetriesFollowTheFirstTry() {
		XCTAssertEqual(delay(after: 1, .failed), .seconds(1))
		XCTAssertEqual(delay(after: 2, .failed), .seconds(3))
		XCTAssertEqual(delay(after: 3, .failed), .seconds(8))
	}

	func testASpentScheduleStops() {
		XCTAssertNil(delay(after: 4, .failed))
		XCTAssertNil(delay(after: 9, .failed))
	}

	func testAResultStopsTheSchedule() {
		XCTAssertNil(delay(after: 1, .found(result)))
		XCTAssertNil(delay(after: 2, .found(result)))
	}

	func testFourFailuresProduceThreeDelaysThenStop() {
		// The loop the panel runs: ask, then wait, while the policy keeps offering a delay.
		var waits: [Duration] = []
		for tryNumber in 1...5 {
			guard let delay = delay(after: tryNumber, .failed) else { break }
			waits.append(delay)
		}
		XCTAssertEqual(waits, [.seconds(1), .seconds(3), .seconds(8)])
	}

	func testAResultOnTheSecondTryEndsTheSchedule() {
		var waits: [Duration] = []
		for (index, outcome) in [LyricsOutcome<LyricsResult>.failed, .found(result)].enumerated() {
			guard let delay = delay(after: index + 1, outcome) else { break }
			waits.append(delay)
		}
		XCTAssertEqual(waits, [.seconds(1)])
	}

	func testAMissIsNeverRetried() {
		// A miss is a real answer; asking again would only spend a request.
		XCTAssertNil(delay(after: 1, .notFound))
		XCTAssertNil(delay(after: 2, .notFound))
		XCTAssertNil(delay(after: 3, .notFound))
	}
}
