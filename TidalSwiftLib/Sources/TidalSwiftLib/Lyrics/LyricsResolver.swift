//
//  LyricsResolver.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
@_exported import LRCParser

/// Which provider a resolved lyrics result came from.
public nonisolated enum LyricsSource: Equatable, Codable, Sendable {
	case tidal
	case lrclib
}

/// Lyrics resolved for a track. `LyricsResolver` only hands out results with
/// something to render, so a `.found` outcome always has lines or plain text.
///
/// `nonisolated` because a result is built and read inside the caches' actors as well
/// as on the main actor.
public nonisolated struct LyricsResult: Equatable, Sendable {
	/// Timed lines parsed from the winning LRC document; empty when the winner
	/// has no LRC (render `plainText` instead).
	public let lines: [LyricLine]
	/// Plain, untimed lyrics from the winning source, when it has any.
	public let plainText: String?
	/// The provider the result came from.
	public let source: LyricsSource

	public init(lines: [LyricLine], plainText: String?, source: LyricsSource) {
		self.lines = lines
		self.plainText = plainText
		self.source = source
	}
}

/// The track metadata LRCLIB needs, plus the Tidal track id used for caching.
public struct LyricsQuery {
	public let trackId: Int
	public let title: String
	public let artistName: String
	public let albumName: String
	public let duration: Int

	public init(trackId: Int, title: String, artistName: String, albumName: String, duration: Int) {
		self.trackId = trackId
		self.title = title
		self.artistName = artistName
		self.albumName = albumName
		self.duration = duration
	}
}

/// Resolves lyrics for a track from Tidal's v2 API with an optional LRCLIB
/// fallback, applying the precedence rule:
///
/// 1. Tidal has LRC → Tidal (LRCLIB is never asked).
/// 2. Tidal has nothing → LRCLIB (LRC if present, else plain).
/// 3. Tidal has plain only → ask LRCLIB; LRCLIB LRC wins, otherwise Tidal's plain.
/// 4. Fallback off → Tidal only.
///
/// The result separates a genuine miss from a failed fetch, so a caller can
/// offer a retry in the second case instead of claiming there are no lyrics.
public struct LyricsResolver {
	public typealias TidalFetcher = (Int) async -> LyricsOutcome<TidalLyrics>
	public typealias LRCLIBFetcher = (String, String, String, Int) async -> LyricsOutcome<LRCLIBLyrics>

	private let tidalFetcher: TidalFetcher
	private let lrclibFetcher: LRCLIBFetcher
	private let cache: LyricsCache
	/// Absent for a resolver that should stay in memory only, which is what a test
	/// wants: nobody's real lyrics folder should depend on a test run.
	private let diskCache: LyricsDiskCache?

	public init(tidalFetcher: @escaping TidalFetcher, lrclibFetcher: @escaping LRCLIBFetcher) {
		self.init(tidalFetcher: tidalFetcher, lrclibFetcher: lrclibFetcher, cache: LyricsCache())
	}

	/// Designated initializer, so a caller with a longer-lived cache (the app's
	/// `Session`) can share one cache across the resolvers it builds.
	init(
		tidalFetcher: @escaping TidalFetcher,
		lrclibFetcher: @escaping LRCLIBFetcher,
		cache: LyricsCache,
		diskCache: LyricsDiskCache? = nil
	) {
		self.tidalFetcher = tidalFetcher
		self.lrclibFetcher = lrclibFetcher
		self.cache = cache
		self.diskCache = diskCache
	}

	/// A resolver backed by a live `Session`, sharing the session's caches so a
	/// result survives the view that requested it, and a relaunch.
	public init(session: Session) {
		self.init(
			tidalFetcher: { await session.trackLyrics(trackId: $0) },
			lrclibFetcher: { await session.lrclibLyrics(trackName: $0, artistName: $1, albumName: $2, duration: $3) },
			cache: session.lyricsCache,
			diskCache: session.lyricsDiskCache
		)
	}

	/// Resolves lyrics for `track`, consulting LRCLIB only when the precedence
	/// rule requires it. Results are cached per track id, in memory and on disk.
	public func lyrics(for track: Track, preferLRCLIB: Bool) async -> LyricsOutcome<LyricsResult> {
		await lyrics(
			for: LyricsQuery(
				trackId: track.id,
				title: track.title,
				artistName: track.artists.first?.name ?? "",
				albumName: track.album.title,
				duration: track.duration
			),
			preferLRCLIB: preferLRCLIB
		)
	}

	/// Resolves lyrics from raw track metadata. Same rule as `lyrics(for:preferLRCLIB:)`.
	public func lyrics(for query: LyricsQuery, preferLRCLIB: Bool) async -> LyricsOutcome<LyricsResult> {
		if case .hit(let cached) = await cachedResult(trackId: query.trackId, preferLRCLIB: preferLRCLIB) {
			return .found(cached)
		}
		let tidal = await tidalFetcher(query.trackId)
		var lrclib = LyricsOutcome<LRCLIBLyrics>.notFound
		if preferLRCLIB, tidal.value?.lrc?.nonEmpty == nil {
			lrclib = await lrclibFetcher(query.title, query.artistName, query.albumName, query.duration)
		}
		var outcome = Self.decide(tidal: tidal, lrclib: lrclib, preferLRCLIB: preferLRCLIB)
		// A result with nothing to render is a miss, not an answer: caching it would
		// make the panel's retry replay it instead of asking again.
		if case .found(let result) = outcome, !Self.hasContent(result) {
			outcome = .notFound
		}
		// Only real results are cached. A miss or a failure must stay a cache miss
		// so the next ask refetches instead of replaying a stale non-answer.
		switch outcome {
		case .found(let result):
			await cache.store(result, trackId: query.trackId, preferLRCLIB: preferLRCLIB)
			await diskCache?.store(result, trackId: query.trackId, preferLRCLIB: preferLRCLIB)
			lyricsLogger.debug("lyrics resolved track=\(query.trackId, privacy: .public) source=\(String(describing: result.source), privacy: .public) lines=\(result.lines.count, privacy: .public)")
		case .notFound, .failed:
			let kind = outcome.isFailure ? "failed" : "notFound"
			lyricsLogger.debug("lyrics resolved track=\(query.trackId, privacy: .public) outcome=\(kind, privacy: .public)")
		}
		return outcome
	}

	/// Memory first, then disk. A disk hit is promoted into memory, so the rest of this
	/// session reads that track without touching the disk again.
	private func cachedResult(trackId: Int, preferLRCLIB: Bool) async -> LyricsCacheLookup {
		if case .hit(let cached) = await cache.lookup(trackId: trackId, preferLRCLIB: preferLRCLIB) {
			return .hit(cached)
		}
		guard let diskCache,
			  case .hit(let cached) = await diskCache.lookup(trackId: trackId, preferLRCLIB: preferLRCLIB) else {
			return .miss
		}
		await cache.store(cached, trackId: trackId, preferLRCLIB: preferLRCLIB)
		return .hit(cached)
	}

	/// The pure precedence rule. Exposed for tests and for callers that already
	/// have both fetches in hand.
	///
	/// Any real result wins over a failure elsewhere: partial information beats
	/// none. With no result, a failed leg means the answer is unknown, not absent.
	public static func decide(
		tidal: LyricsOutcome<TidalLyrics>,
		lrclib: LyricsOutcome<LRCLIBLyrics>,
		preferLRCLIB: Bool
	) -> LyricsOutcome<LyricsResult> {
		let tidalLRC = tidal.value?.lrc?.nonEmpty
		let tidalPlain = tidal.value?.plain?.nonEmpty
		let lrclibLRC = lrclib.value?.lrc?.nonEmpty
		let lrclibPlain = lrclib.value?.plain?.nonEmpty

		if let tidalLRC {
			return .found(LyricsResult(lines: LRCParser.parse(tidalLRC), plainText: tidalPlain, source: .tidal))
		}
		if preferLRCLIB, let lrclibLRC {
			return .found(LyricsResult(lines: LRCParser.parse(lrclibLRC), plainText: lrclibPlain, source: .lrclib))
		}
		if let tidalPlain {
			return .found(LyricsResult(lines: [], plainText: tidalPlain, source: .tidal))
		}
		if preferLRCLIB, let lrclibPlain {
			return .found(LyricsResult(lines: [], plainText: lrclibPlain, source: .lrclib))
		}
		let consultedLRCLIB = preferLRCLIB && lrclib.isFailure
		return tidal.isFailure || consultedLRCLIB ? .failed : .notFound
	}

	/// Whether there is anything to put on screen. Timed text that parses to no
	/// lines, with no plain text beside it, is a provider bug rather than lyrics.
	static func hasContent(_ result: LyricsResult) -> Bool {
		!result.lines.isEmpty || result.plainText?.nonEmpty != nil
	}
}

/// Result of a cache lookup: `.miss` when nothing is cached for the track (or
/// it was cached under a different fallback setting), `.hit` otherwise.
enum LyricsCacheLookup {
	case miss
	case hit(LyricsResult)
}

/// In-memory, per-track cache for resolved lyrics. `LyricsDiskCache` holds the same
/// results across launches; this holds the ones read this session.
///
/// Shared by every `LyricsResolver` a `Session` builds, so a result survives
/// the view that triggered resolution. Bounded so a long session cannot hold
/// lyrics for an unbounded number of tracks. Only successful resolutions are
/// stored; misses are never cached.
actor LyricsCache {
	private struct Entry {
		let preferLRCLIB: Bool
		let result: LyricsResult
	}

	private var entries: [Int: Entry] = [:]
	/// Track ids in insertion order, oldest first, used for eviction.
	private var order: [Int] = []
	private let limit: Int

	init(limit: Int = 200) {
		self.limit = limit
	}

	func lookup(trackId: Int, preferLRCLIB: Bool) -> LyricsCacheLookup {
		guard let entry = entries[trackId], entry.preferLRCLIB == preferLRCLIB else { return .miss }
		return .hit(entry.result)
	}

	func store(_ result: LyricsResult, trackId: Int, preferLRCLIB: Bool) {
		if entries[trackId] == nil {
			order.append(trackId)
			if order.count > limit {
				entries[order.removeFirst()] = nil
			}
		}
		entries[trackId] = Entry(preferLRCLIB: preferLRCLIB, result: result)
	}
}
