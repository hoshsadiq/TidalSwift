//
//  ScrollingLineTiming.swift
//  TidalSwiftLib
//

import Foundation

/// The clock behind `ScrollingLine`'s scroll: where in its loop the line sits at
/// a given moment, and how a pause, a resume and a restart move that.
///
/// It is plain arithmetic, with no view and no timer, so the schedules this
/// scroll keeps being argued about — a restart while paused, a resume after the
/// delay — can be exercised on their own.
///
/// A paused `TimelineView` keeps handing its content the date it froze at, so
/// that date cannot place the line during a pause. The fraction shown when the
/// pause began is held in `pausedPhase` instead, and a restart while paused
/// overwrites it, which is what keeps the drawn offset from drifting away from
/// the loop the line is actually on.
public nonisolated struct ScrollingLineTiming: Equatable, Sendable {
	/// When the current loop began; the phase counts forward from here.
	public private(set) var anchor: Date
	/// When the pause began, or `nil` while the line is running.
	public private(set) var pausedAt: Date?
	/// The loop fraction the line was showing when the pause began.
	public private(set) var pausedPhase: Double

	public init(anchor: Date) {
		self.anchor = anchor
		self.pausedAt = nil
		self.pausedPhase = 0
	}

	public var isPaused: Bool { pausedAt != nil }

	/// One loop's duration: the width the line travels per cycle at its speed,
	/// floored at a second so a very short line cannot spin.
	public static func period(loopWidth: CGFloat, pointsPerSecond: Double) -> Double {
		max(1, Double(loopWidth) / pointsPerSecond)
	}

	/// The completed fraction of one loop at `date`, in `[0, 1)`.
	public func phase(at date: Date, period: Double) -> Double {
		let fraction = date.timeIntervalSince(anchor).truncatingRemainder(dividingBy: period) / period
		return fraction < 0 ? fraction + 1 : fraction
	}

	/// Puts the line back at the start of its loop.
	///
	/// A pause measures its resume shift from `pausedAt`, so a restart while
	/// paused has to move that mark too: otherwise the shift would replay time
	/// the restarted phase no longer counts. The held fraction goes to zero for
	/// the same reason — the new loop is at its start, not at the old fraction.
	public mutating func restart(at date: Date) {
		anchor = date
		if isPaused {
			pausedAt = date
			pausedPhase = 0
		}
	}

	/// Freezes the loop fraction the line is showing.
	public mutating func pause(at date: Date, period: Double) {
		pausedAt = date
		pausedPhase = phase(at: date, period: period)
	}

	/// Starts the loop again, keeping the fraction it had when it stopped: the
	/// anchor moves by however long the pause lasted, so `phase` picks up where
	/// the held `pausedPhase` left off.
	public mutating func resume(at date: Date) {
		guard let pausedAt else { return }
		anchor = anchor.addingTimeInterval(date.timeIntervalSince(pausedAt))
		self.pausedAt = nil
	}
}
