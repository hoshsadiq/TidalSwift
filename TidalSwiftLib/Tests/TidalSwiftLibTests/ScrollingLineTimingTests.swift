//
//  ScrollingLineTimingTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the scroll's clock: the period drawn from a line's width, the phase across
/// a cycle, and what a pause, a resume and a restart do to it. These are the
/// sequences the hovered-line behaviour keeps hinging on.
final class ScrollingLineTimingTests: XCTestCase {
	private let t0 = Date(timeIntervalSinceReferenceDate: 0)

	private func time(_ offset: TimeInterval) -> Date {
		t0.addingTimeInterval(offset)
	}

	func testPeriodDividesTheLoopWidthByItsSpeed() {
		XCTAssertEqual(
			ScrollingLineTiming.period(loopWidth: 300, pointsPerSecond: 30),
			10,
			accuracy: 0.0001
		)
		XCTAssertEqual(
			ScrollingLineTiming.period(loopWidth: 48, pointsPerSecond: 30),
			1.6,
			accuracy: 0.0001
		)
	}

	func testPeriodIsFlooredAtOneSecond() {
		XCTAssertEqual(
			ScrollingLineTiming.period(loopWidth: 3, pointsPerSecond: 30),
			1,
			accuracy: 0.0001
		)
		XCTAssertEqual(
			ScrollingLineTiming.period(loopWidth: 0, pointsPerSecond: 30),
			1,
			accuracy: 0.0001
		)
	}

	func testOverflowIsClaimedOnlyWhenTheLineIsWiderThanItsSpace() {
		XCTAssertFalse(ScrollingLineTiming.overflows(lineWidth: 200, availableWidth: 300))
		XCTAssertFalse(ScrollingLineTiming.overflows(lineWidth: 300, availableWidth: 300))
		XCTAssertTrue(ScrollingLineTiming.overflows(lineWidth: 302, availableWidth: 300))
	}

	func testOverflowWithinTheRoundingSlackDoesNotScroll() {
		// A line a fraction of a point wider than its space still fits; the slack
		// stops sub-point rounding from starting a line that does not need it.
		XCTAssertFalse(ScrollingLineTiming.overflows(lineWidth: 300.5, availableWidth: 300))
		XCTAssertFalse(ScrollingLineTiming.overflows(lineWidth: 301, availableWidth: 300))
	}

	func testOverflowIsNotClaimedBeforeAWidthIsOffered() {
		// The offered width reads zero until the first layout pass. A real line is
		// wider than that, so claiming an overflow here would scroll every line.
		XCTAssertFalse(ScrollingLineTiming.overflows(lineWidth: 369, availableWidth: 0))
		XCTAssertFalse(ScrollingLineTiming.overflows(lineWidth: 0, availableWidth: 0))
	}

	func testPhaseAcrossTheCycleWrapsAtThePeriod() {
		let timing = ScrollingLineTiming(anchor: t0)
		let cases: [(offset: TimeInterval, phase: Double)] = [
			(0, 0),
			(2.5, 0.25),
			(5, 0.5),
			(9.75, 0.975),
			(10, 0),
			(12.5, 0.25)
		]
		for (offset, expected) in cases {
			XCTAssertEqual(
				timing.phase(at: time(offset), period: 10),
				expected,
				accuracy: 0.0001,
				"at \(offset)s"
			)
		}
	}

	func testPhaseBeforeTheAnchorWrapsForward() {
		let timing = ScrollingLineTiming(anchor: time(10))
		XCTAssertEqual(timing.phase(at: time(7.5), period: 10), 0.75, accuracy: 0.0001)
	}

	func testRestartPutsTheLineAtTheStartOfItsLoop() {
		var timing = ScrollingLineTiming(anchor: t0)
		timing.restart(at: time(4))
		XCTAssertEqual(timing.phase(at: time(4), period: 10), 0, accuracy: 0.0001)
		XCTAssertEqual(timing.phase(at: time(6.5), period: 10), 0.25, accuracy: 0.0001)
		XCTAssertNil(timing.pausedAt)
	}

	func testPauseHoldsThePhaseTheLineWasShowing() {
		var timing = ScrollingLineTiming(anchor: t0)
		timing.pause(at: time(2.5), period: 10)
		XCTAssertTrue(timing.isPaused)
		XCTAssertEqual(timing.pausedAt, time(2.5))
		XCTAssertEqual(timing.pausedPhase, 0.25, accuracy: 0.0001)
	}

	func testRestartWhilePausedMovesBothTimestampsAndZeroesThePhase() {
		var timing = ScrollingLineTiming(anchor: t0)
		timing.pause(at: time(2.5), period: 10)
		timing.restart(at: time(4))
		XCTAssertTrue(timing.isPaused)
		XCTAssertEqual(timing.anchor, time(4))
		XCTAssertEqual(timing.pausedAt, time(4))
		XCTAssertEqual(timing.pausedPhase, 0, accuracy: 0.0001)
		XCTAssertEqual(timing.phase(at: time(4), period: 10), 0, accuracy: 0.0001)
	}

	func testResumeKeepsThePhaseItHad() {
		var timing = ScrollingLineTiming(anchor: t0)
		timing.pause(at: time(2.5), period: 10)
		// A pause of 10.75s against a 10s loop: the anchor moves by the whole
		// pause, so the train picks up at the held fraction rather than at the
		// raw gap between the two dates.
		timing.resume(at: time(13.25))
		XCTAssertFalse(timing.isPaused)
		XCTAssertEqual(timing.phase(at: time(13.25), period: 10), 0.25, accuracy: 0.0001)
		XCTAssertEqual(timing.phase(at: time(14.75), period: 10), 0.4, accuracy: 0.0001)
	}

	func testResumeAfterARestartWhilePausedStartsFromTheBeginning() {
		var timing = ScrollingLineTiming(anchor: t0)
		timing.pause(at: time(2.5), period: 10)
		timing.restart(at: time(4))
		timing.resume(at: time(6.6))
		XCTAssertFalse(timing.isPaused)
		XCTAssertEqual(timing.phase(at: time(6.6), period: 10), 0, accuracy: 0.0001)
		XCTAssertEqual(timing.phase(at: time(9.1), period: 10), 0.25, accuracy: 0.0001)
	}

	func testResumeWithoutAPauseLeavesTheAnchorAlone() {
		var timing = ScrollingLineTiming(anchor: t0)
		timing.resume(at: time(5))
		XCTAssertEqual(timing.anchor, t0)
		XCTAssertFalse(timing.isPaused)
	}
}
