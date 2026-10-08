//
//  PlaybackCache.swift
//  TidalSwiftLib
//

import Foundation

/// The playback cache, at `~/Library/Caches/TidalSwift/stream/`. Never the offline library:
/// these files are a playback cache, not the user's music. The rung is in the name because a
/// Max file must never be served as Lossless, nor an Atmos file as a stereo tier, or the badge
/// would lie.
///
/// Every tier is one assembled HLS file, so the cache holds one shape. It is bounded on launch
/// and after every write: files not touched in a week are dropped, then the least recently used
/// until the directory is under the configured size.
public nonisolated enum PlaybackCache {
	static let maxAge: TimeInterval = 7 * 24 * 60 * 60

	public static var directory: URL {
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("TidalSwift/stream", isDirectory: true)
	}

	static func fileURL(forTrackId trackId: Int, rung: HLSRung, in directory: URL = PlaybackCache.directory) -> URL {
		directory.appendingPathComponent("\(trackId)-\(rung.fileMarker).m4a")
	}

	static func cachedFile(forTrackId trackId: Int, rung: HLSRung, in directory: URL = PlaybackCache.directory) -> URL? {
		let url = fileURL(forTrackId: trackId, rung: rung, in: directory)
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		guard HLSStreaming.isPlayableMP4File(at: url) else {
			try? FileManager.default.removeItem(at: url)
			return nil
		}
		return url
	}

	/// The first rung in `rungs` order with a complete cached file, with the rung its name
	/// carries. A play asks with the rung ladder, so a track whose chosen rung was refused
	/// and cached one rung down is still served from disk, and the badge reads the rung that
	/// actually played rather than the one that was asked for.
	static func cachedFile(
		forTrackId trackId: Int,
		rungs: [HLSRung],
		in directory: URL = PlaybackCache.directory
	) -> (url: URL, rung: HLSRung)? {
		for rung in rungs {
			if let url = cachedFile(forTrackId: trackId, rung: rung, in: directory) {
				return (url, rung)
			}
		}
		return nil
	}

	public static func usageBytes(in directory: URL = PlaybackCache.directory) -> Int {
		let keys: Set<URLResourceKey> = [.fileSizeKey]
		guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
			return 0
		}
		return contents.reduce(0) { total, url in
			total + ((try? url.resourceValues(forKeys: keys).fileSize) ?? 0)
		}
	}

	/// Marks a cache file as recently used, so LRU eviction keeps what plays.
	static func touch(_ url: URL, now: Date = Date()) {
		try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
	}

	public static func pruneIfNeeded(protecting trackIds: Set<Int> = [], queueTrackIds: Set<Int> = [], now: Date = Date()) {
		pruneIfNeeded(in: directory, protecting: trackIds, queueTrackIds: queueTrackIds, now: now)
	}

	static func pruneIfNeeded(in directory: URL, protecting trackIds: Set<Int> = [], queueTrackIds: Set<Int> = [], now: Date = Date()) {
		prune(in: directory, maxBytes: PlaybackCachePreferences.cacheSizeBytes, maxAge: maxAge, protecting: trackIds, queueTrackIds: queueTrackIds, now: now)
	}

	/// Removes stale files first, then the least recently used until under the size cap.
	/// Protected tracks and files in the prefetch window survive even when that leaves the
	/// directory over budget; the removed URLs are returned so a test can pin what went.
	///
	/// The decision is `PlaybackCacheEviction`'s; this only reads its own directory into
	/// entries and deletes the names it returns, so no file outside the cache is reached.
	@discardableResult
	static func prune(in directory: URL, maxBytes: Int, maxAge: TimeInterval, protecting trackIds: Set<Int> = [], queueTrackIds: Set<Int> = [], now: Date = Date()) -> [URL] {
		let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
		guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
			return []
		}
		let entries = contents.compactMap { url -> PlaybackCacheEviction.Entry? in
			guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
			return PlaybackCacheEviction.Entry(
				name: url.lastPathComponent,
				size: values.fileSize ?? 0,
				lastUsed: values.contentModificationDate ?? .distantPast
			)
		}
		let doomed = PlaybackCacheEviction.evictions(
			entries: entries,
			protectedTrackIds: trackIds,
			queueTrackIds: queueTrackIds,
			limits: .init(budgetBytes: maxBytes, maxAge: maxAge, now: now)
		)
		var removed: [URL] = []
		for entry in doomed {
			let url = directory.appendingPathComponent(entry.name)
			try? FileManager.default.removeItem(at: url)
			removed.append(url)
		}
		return removed
	}
}

/// The playback-cache preferences, owned by the library so the player and the settings read them.
/// Default on: the cache and prefetch run unless a user opts out.
public nonisolated enum PlaybackCachePreferences {
	// The stored keys keep their original spelling so an existing preference is not reset.
	public static let prefetchDepthKey = "hiResStreamPrefetchDepth"
	public static let cacheSizeBytesKey = "hiResStreamCacheBytes"

	/// How many tracks after the current one are prepared in advance; 0 turns it off.
	public static let defaultPrefetchDepth = 3
	public static let prefetchDepthRange = 0...15
	public static let prefetchDepthOptions: [Int] = [0, 1, 2, 3, 5, 8, 10, 15]

	public static var prefetchDepth: Int {
		guard UserDefaults.standard.object(forKey: prefetchDepthKey) != nil else {
			return defaultPrefetchDepth
		}
		return min(max(UserDefaults.standard.integer(forKey: prefetchDepthKey), prefetchDepthRange.lowerBound), prefetchDepthRange.upperBound)
	}

	/// How much disk space prepared tracks may use; the prefetch window and current track are exempt.
	public static let defaultCacheBytes = 2 * 1024 * 1024 * 1024
	/// The budget in gigabytes, bounded so a typo cannot zero it or claim the whole
	/// disk. The stored value is in bytes.
	public static let cacheSizeRange = 1...64

	static let bytesPerGigabyte = 1024 * 1024 * 1024

	public static var cacheSizeBytes: Int {
		cacheSizeBytes(in: .standard)
	}

	/// The stored budget in bytes, clamped to `cacheSizeRange` on read.
	static func cacheSizeBytes(in defaults: UserDefaults) -> Int {
		guard defaults.object(forKey: cacheSizeBytesKey) != nil else {
			return defaultCacheBytes
		}
		let lower = cacheSizeRange.lowerBound * bytesPerGigabyte
		let upper = cacheSizeRange.upperBound * bytesPerGigabyte
		return min(max(defaults.integer(forKey: cacheSizeBytesKey), lower), upper)
	}
}
