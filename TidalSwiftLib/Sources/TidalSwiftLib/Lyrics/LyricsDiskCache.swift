//
//  LyricsDiskCache.swift
//  TidalSwiftLib
//

import Foundation

/// Resolved lyrics kept on disk, under the container's caches directory at
/// `…/Caches/TidalSwift/lyrics/`, resolved the same way `PlaybackCache` resolves its own root.
///
/// A result outlives the process here, so a relaunch serves lyrics from disk instead of
/// asking both providers again. Only real results are written, each tagged with the LRCLIB
/// preference it was resolved under, so a lookup under the other preference is a miss. Lyrics
/// do not go stale, so there is no age limit: the folder is capped by size and trimmed least
/// recently used, through the shared `PlaybackCacheEviction` table, which keys on the
/// `<track id>-` file-name convention this cache uses too.
actor LyricsDiskCache {
	/// A cached document is a few kilobytes of JSON, so this holds roughly a thousand
	/// tracks: more than a long listening history, and small beside the playback cache.
	static let budgetBytes = 4 * 1024 * 1024

	/// The container's caches directory, not `~/Library/Caches` of the user.
	nonisolated static var directory: URL {
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("TidalSwift/lyrics", isDirectory: true)
	}

	private let directory: URL
	private let budgetBytes: Int

	init(directory: URL = LyricsDiskCache.directory, budgetBytes: Int = LyricsDiskCache.budgetBytes) {
		self.directory = directory
		self.budgetBytes = budgetBytes
	}

	func lookup(trackId: Int, preferLRCLIB: Bool) -> LyricsCacheLookup {
		let url = fileURL(trackId: trackId)
		guard let data = try? Data(contentsOf: url) else { return .miss }
		guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
			// An unreadable file can never be served, so it may as well stop taking space.
			try? FileManager.default.removeItem(at: url)
			return .miss
		}
		guard entry.preferLRCLIB == preferLRCLIB else { return .miss }
		// The modification date is the eviction order, so reading a file is what keeps it.
		try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
		return .hit(entry.result)
	}

	func store(_ result: LyricsResult, trackId: Int, preferLRCLIB: Bool) {
		guard let data = try? JSONEncoder().encode(Entry(preferLRCLIB: preferLRCLIB, result: result)) else { return }
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		// Atomic: a half-written document would decode as corrupt and read as a miss.
		try? data.write(to: fileURL(trackId: trackId), options: .atomic)
		prune()
	}

	/// Removes the least recently used documents until the folder is under budget, and
	/// returns what went so a test can pin it.
	@discardableResult
	func prune(now: Date = Date()) -> [URL] {
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
			protectedTrackIds: [],
			queueTrackIds: [],
			// No age limit; the sky-high bound keeps the table from evicting on age alone.
			limits: .init(budgetBytes: budgetBytes, maxAge: .greatestFiniteMagnitude, now: now)
		)
		var removed: [URL] = []
		for entry in doomed {
			let url = directory.appendingPathComponent(entry.name)
			try? FileManager.default.removeItem(at: url)
			removed.append(url)
		}
		return removed
	}

	/// The name carries the track id so the shared eviction table can read it.
	private func fileURL(trackId: Int) -> URL {
		directory.appendingPathComponent("\(trackId)-lyrics.json")
	}

	/// The on-disk shape. `LyricLine` is the parser's type and stays out of the file format,
	/// so a parser change cannot make every cached document unreadable.
	private struct Entry: Codable {
		struct Line: Codable {
			let time: TimeInterval
			let text: String
		}

		let preferLRCLIB: Bool
		let source: LyricsSource
		let plainText: String?
		let lines: [Line]

		init(preferLRCLIB: Bool, result: LyricsResult) {
			self.preferLRCLIB = preferLRCLIB
			self.source = result.source
			self.plainText = result.plainText
			self.lines = result.lines.map { Line(time: $0.time, text: $0.text) }
		}

		var result: LyricsResult {
			LyricsResult(
				lines: lines.map { LyricLine(time: $0.time, text: $0.text) },
				plainText: plainText,
				source: source
			)
		}
	}
}
