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
public enum LyricsSource: Equatable {
	case tidal
	case lrclib
}

/// The outcome of resolving lyrics for a track.
public struct LyricsResult: Equatable {
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
public struct LyricsResolver {
	public typealias TidalFetcher = (Int) async -> TidalLyrics?
	public typealias LRCLIBFetcher = (String, String, String, Int) async -> LRCLIBLyrics?

	private let tidalFetcher: TidalFetcher
	private let lrclibFetcher: LRCLIBFetcher
	private let cache: LyricsCache

	public init(tidalFetcher: @escaping TidalFetcher, lrclibFetcher: @escaping LRCLIBFetcher) {
		self.init(tidalFetcher: tidalFetcher, lrclibFetcher: lrclibFetcher, cache: LyricsCache())
	}

	/// Designated initializer, so a caller with a longer-lived cache (the app's
	/// `Session`) can share one cache across the resolvers it builds.
	init(tidalFetcher: @escaping TidalFetcher, lrclibFetcher: @escaping LRCLIBFetcher, cache: LyricsCache) {
		self.tidalFetcher = tidalFetcher
		self.lrclibFetcher = lrclibFetcher
		self.cache = cache
	}

	/// A resolver backed by a live `Session`, sharing the session's lyrics cache
	/// so results survive the view that requested them being rebuilt.
	public init(session: Session) {
		self.init(
			tidalFetcher: { await session.trackLyrics(trackId: $0) },
			lrclibFetcher: { await session.lrclibLyrics(trackName: $0, artistName: $1, albumName: $2, duration: $3) },
			cache: session.lyricsCache
		)
	}

	/// Resolves lyrics for `track`, consulting LRCLIB only when the precedence
	/// rule requires it. Results are cached in memory per track id.
	public func lyrics(for track: Track, preferLRCLIB: Bool) async -> LyricsResult? {
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
	public func lyrics(for query: LyricsQuery, preferLRCLIB: Bool) async -> LyricsResult? {
		if case .hit(let cached) = await cache.lookup(trackId: query.trackId, preferLRCLIB: preferLRCLIB) {
			return cached
		}
		let tidal = await tidalFetcher(query.trackId)
		var lrclib: LRCLIBLyrics?
		if preferLRCLIB, tidal?.lrc?.nonEmpty == nil {
			lrclib = await lrclibFetcher(query.title, query.artistName, query.albumName, query.duration)
		}
		let result = Self.decide(tidal: tidal, lrclib: lrclib, preferLRCLIB: preferLRCLIB)
		// Only successful resolutions are cached; a nil (nothing found, or a
		// transient fetch failure) must stay a cache miss so the retry button
		// actually refetches instead of re-reading a cached nil.
		if let result {
			await cache.store(result, trackId: query.trackId, preferLRCLIB: preferLRCLIB)
		}
		lyricsLogger.debug("lyrics resolved track=\(query.trackId, privacy: .public) source=\(String(describing: result?.source), privacy: .public) lines=\(result?.lines.count ?? 0, privacy: .public)")
		return result
	}

	/// The pure precedence rule. Exposed for tests and for callers that already
	/// have both fetches in hand.
	public static func decide(tidal: TidalLyrics?, lrclib: LRCLIBLyrics?, preferLRCLIB: Bool) -> LyricsResult? {
		let tidalLRC = tidal?.lrc?.nonEmpty
		let tidalPlain = tidal?.plain?.nonEmpty
		let lrclibLRC = lrclib?.lrc?.nonEmpty
		let lrclibPlain = lrclib?.plain?.nonEmpty

		if let tidalLRC {
			return LyricsResult(lines: LRCParser.parse(tidalLRC), plainText: tidalPlain, source: .tidal)
		}
		guard preferLRCLIB else {
			return tidalPlain.map { LyricsResult(lines: [], plainText: $0, source: .tidal) }
		}
		if let lrclibLRC {
			return LyricsResult(lines: LRCParser.parse(lrclibLRC), plainText: lrclibPlain, source: .lrclib)
		}
		if let tidalPlain {
			return LyricsResult(lines: [], plainText: tidalPlain, source: .tidal)
		}
		if let lrclibPlain {
			return LyricsResult(lines: [], plainText: lrclibPlain, source: .lrclib)
		}
		return nil
	}
}

/// Result of a cache lookup: `.miss` when nothing is cached for the track (or
/// it was cached under a different fallback setting), `.hit` otherwise.
enum LyricsCacheLookup {
	case miss
	case hit(LyricsResult)
}

/// In-memory, per-track cache for resolved lyrics. No disk persistence.
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
