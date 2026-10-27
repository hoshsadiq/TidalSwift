//
//  LyricsDiskCache.swift
//  TidalSwiftLib
//

import Foundation

/// Resolved lyrics kept on disk, at `~/Library/Caches/TidalSwift/lyrics/`, resolved the same
/// way `PlaybackCache` resolves its own root: the user's caches directory, which a signed,
/// sandboxed build places inside the app's container.
///
/// A result outlives the process here, so a relaunch serves lyrics from disk instead of
/// asking both providers again. Only real results are written, each tagged with the LRCLIB
/// preference it was resolved under, so a lookup under the other preference is a miss. Lyrics
/// do not go stale, so there is no age limit: the folder is capped by size and trimmed least
/// recently used, through the shared `PlaybackCacheEviction` table, which keys on the
/// `<track id>-` file-name convention this cache uses too.
actor LyricsDiskCache {
	/// A stored document runs from about 2 KB for a short song to about 10 KB for a long one
	/// that carries both timed lines and plain text, so 4 MB holds roughly 400 to 700 tracks.
	/// That is still more than a long listening history, and small beside a playback cache
	/// measured in gigabytes.
	static let budgetBytes = 4 * 1024 * 1024

	/// Nothing larger than this is written, and a larger file on disk is treated as foreign
	/// and dropped: a provider bug should not park a megabyte of text in the cache.
	static let maxDocumentBytes = 512 * 1024

	/// The caches directory, which a sandboxed build resolves inside its container.
	nonisolated static var directory: URL {
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
			?? FileManager.default.temporaryDirectory
		return base.appendingPathComponent("TidalSwift/lyrics", isDirectory: true)
	}

	private let directory: URL
	private let budgetBytes: Int

	init(directory: URL = LyricsDiskCache.directory, budgetBytes: Int = LyricsDiskCache.budgetBytes) {
		self.directory = directory
		self.budgetBytes = budgetBytes
	}

	func lookup(trackId: Int, preferLRCLIB: Bool) -> LyricsCacheLookup {
		guard let url = fileURL(trackId: trackId) else { return .miss }
		guard let entry = readableEntry(at: url) else { return .miss }
		guard entry.preferLRCLIB == preferLRCLIB else { return .miss }
		// The modification date is the eviction order, so reading a file is what keeps it.
		try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
		return .hit(entry.result)
	}

	func store(_ result: LyricsResult, trackId: Int, preferLRCLIB: Bool) {
		guard let url = fileURL(trackId: trackId),
			  let data = try? JSONEncoder().encode(Entry(preferLRCLIB: preferLRCLIB, result: result)),
			  data.count <= Self.maxDocumentBytes else { return }
		// Only this process should be able to read what it cached. The mode is set after
		// creating, because `createDirectory` only applies attributes to a folder it made
		// itself, and an existing loose folder would keep its mode.
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
		// Atomic: a half-written document would decode as corrupt and read as a miss.
		guard (try? data.write(to: url, options: .atomic)) != nil else { return }
		try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
		prune()
	}

	/// A document is only served when it is a regular file this cache could have written.
	/// A link or an oversized file belongs to something else, so it is dropped rather than
	/// read or followed.
	private func readableEntry(at url: URL) -> Entry? {
		let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
		guard let values = try? url.resourceValues(forKeys: keys),
			  values.isRegularFile == true,
			  let size = values.fileSize,
			  size <= Self.maxDocumentBytes else {
			try? FileManager.default.removeItem(at: url)
			return nil
		}
		guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
			// An unreadable file can never be served, so it may as well stop taking space.
			try? FileManager.default.removeItem(at: url)
			return nil
		}
		return entry
	}

	/// Trims the folder to the budget, oldest document first, and returns what went so a test
	/// can pin it. Lyrics do not go stale, so nothing is dropped for its age.
	@discardableResult
	func prune(now: Date = Date()) -> [URL] {
		PlaybackCacheEviction.pruneFiles(
			in: directory,
			// The sky-high age bound keeps the table from evicting on age alone.
			limits: .init(budgetBytes: budgetBytes, maxAge: .greatestFiniteMagnitude, now: now)
		)
	}

	/// The name carries the track id so the shared eviction table can read it. A track id that
	/// is not positive would produce a name no prune can match, so it is refused here.
	private func fileURL(trackId: Int) -> URL? {
		guard trackId > 0 else { return nil }
		return directory.appendingPathComponent("\(trackId)-lyrics.json")
	}
}

/// The on-disk shape. `LyricLine` is the parser's type and stays out of the file format, so a
/// parser change cannot make every cached document unreadable.
private nonisolated struct Entry: Codable {
	let preferLRCLIB: Bool
	let source: LyricsSource
	let plainText: String?
	let lines: [StoredLine]

	init(preferLRCLIB: Bool, result: LyricsResult) {
		self.preferLRCLIB = preferLRCLIB
		self.source = result.source
		self.plainText = result.plainText
		self.lines = result.lines.map { StoredLine(time: $0.time, text: $0.text) }
	}

	var result: LyricsResult {
		LyricsResult(
			lines: lines.map { LyricLine(time: $0.time, text: $0.text) },
			plainText: plainText,
			source: source
		)
	}
}

private nonisolated struct StoredLine: Codable {
	let time: TimeInterval
	let text: String
}
