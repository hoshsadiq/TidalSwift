//
//  LyricsPrefetcher.swift
//  TidalSwiftLib
//

import Foundation

/// Fetches a track's lyrics once and hands the same answer to everyone who asks.
///
/// Lyrics belong to the track, not to a panel: a play warms them, a download tags them into
/// the file, and a view only reads what is there. Keeping the schedule here rather than in a
/// view is what lets a closed panel leave the fetch alone, and what stops two surfaces on the
/// same track from running two chains.
public final class LyricsPrefetcher {
	public typealias Query = LyricsQuery

	/// The waits and the cap the fetch follows. A test hands in a fast one; the app uses
	/// `standard`, whose numbers stay in `LyricsRetryPolicy` so there is one place to change them.
	public struct Schedule {
		public var delays: [Duration]
		public var totalBudget: Duration

		public static let standard = Schedule(
			delays: LyricsRetryPolicy.delays,
			totalBudget: LyricsRetryPolicy.totalBudget
		)

		public init(delays: [Duration], totalBudget: Duration) {
			self.delays = delays
			self.totalBudget = totalBudget
		}

		/// The wait before the next automatic try, or nil when the schedule is spent.
		func retryDelay(afterCompletedTries completedTries: Int, outcome: LyricsOutcome<LyricsResult>) -> Duration? {
			guard case .failed = outcome else { return nil }
			guard completedTries >= 1, completedTries <= delays.count else { return nil }
			return delays[completedTries - 1]
		}
	}

	private let resolver: LyricsResolver
	private let schedule: Schedule
	/// One task per track, so a second ask joins the first instead of asking again.
	private var running: [Int: Task<LyricsOutcome<LyricsResult>, Never>] = [:]

	public init(resolver: LyricsResolver, schedule: Schedule = .standard) {
		self.resolver = resolver
		self.schedule = schedule
	}

	/// The lyrics for `query`, from the caches, from a downloaded file, or from the fetch
	/// already running for that track. Only a track nobody is fetching starts a request.
	public func lyrics(for query: Query, preferLRCLIB: Bool) async -> LyricsOutcome<LyricsResult> {
		if let existing = running[query.trackId] {
			return await existing.value
		}
		let task = Task { await self.fetchScheduled(query, preferLRCLIB: preferLRCLIB) }
		running[query.trackId] = task
		let outcome = await task.value
		// Cleared so a later ask can try again: a failure is never cached, so the retry
		// button and the next play both get a fresh attempt.
		running[query.trackId] = nil
		return outcome
	}

	/// Warms the lyrics for a track something else is about to want, without waiting for the
	/// answer. Called when a track starts playing and when a download finishes.
	public func prepare(for query: Query, preferLRCLIB: Bool) {
		guard running[query.trackId] == nil else { return }
		running[query.trackId] = Task { [weak self] in
			guard let self else { return .notFound }
			let outcome = await self.fetchScheduled(query, preferLRCLIB: preferLRCLIB)
			self.running[query.trackId] = nil
			return outcome
		}
	}

	/// The lyrics for `query` when the caches or a file already hold them, without waiting on
	/// a fetch that is still running.
	public func cachedLyrics(for query: Query, preferLRCLIB: Bool) async -> LyricsOutcome<LyricsResult>? {
		await resolver.cachedLyrics(for: query, preferLRCLIB: preferLRCLIB)
	}

	/// Tries until an answer arrives or the schedule is spent, under one wall-clock cap. The
	/// waits alone bound nothing: a provider that never answers spends its request timeout
	/// inside each try, so the cap is what stops the work.
	private func fetchScheduled(_ query: Query, preferLRCLIB: Bool) async -> LyricsOutcome<LyricsResult> {
		let work = Task { () -> LyricsOutcome<LyricsResult> in
			var completedTries = 0
			while true {
				let outcome = await self.resolver.lyrics(for: query, preferLRCLIB: preferLRCLIB)
				completedTries += 1
				// A cancelled attempt is a failure whatever the provider handed back: the cap is a
				// stop, not a race it can lose.
				guard !Task.isCancelled else { return .failed }
				guard let delay = self.schedule.retryDelay(afterCompletedTries: completedTries, outcome: outcome) else {
					return outcome
				}
				try? await Task.sleep(for: delay)
				guard !Task.isCancelled else { return .failed }
			}
		}
		let cap = Task {
			try? await Task.sleep(for: self.schedule.totalBudget)
			guard !Task.isCancelled else { return }
			work.cancel()
		}
		defer { cap.cancel() }
		return await work.value
	}
}
