//
//  LyricsRetryPolicy.swift
//  TidalSwiftLib
//

import Foundation

/// The automatic retry schedule for a lyrics fetch.
///
/// Pure, so the delays and the stop rules are testable without a view or a network.
/// Only a failure is retried: a miss is a real answer, and asking again for lyrics a
/// provider says it does not have would spend requests on a decision that cannot change.
public nonisolated enum LyricsRetryPolicy {
	/// The wait before each automatic retry, in order. A fetch therefore makes four tries
	/// at most, the first one plus these three, and the panel offers its button afterwards.
	public static let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]

	/// The wait before the next automatic try, or `nil` when the fetch should stop.
	///
	/// `completedTries` counts the tries already finished, the first one included, so a
	/// fetch that has just failed its first try gets `delays[0]`.
	public static func retryDelay(
		afterCompletedTries completedTries: Int,
		outcome: LyricsOutcome<LyricsResult>
	) -> Duration? {
		// A result stops the schedule, and so does a miss: neither improves by asking again.
		guard case .failed = outcome else { return nil }
		guard completedTries >= 1, completedTries <= delays.count else { return nil }
		return delays[completedTries - 1]
	}
}
