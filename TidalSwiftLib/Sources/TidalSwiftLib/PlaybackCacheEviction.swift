//
//  PlaybackCacheEviction.swift
//  TidalSwiftLib
//

import Foundation

/// The playback cache's eviction table: given what is on disk, what must survive, what is
/// in the queue and a size budget, it decides which files go.
///
/// Pure, so the whole table is testable without a disk. `PlaybackCache.prune` reads its
/// own directory into `Entry` values, asks here, and deletes the returned names — which is
/// why eviction can never reach a file outside that directory.
nonisolated enum PlaybackCacheEviction {
	/// One cached file. The leading `<track id>-` in the name is what ties it to a track.
	struct Entry: Equatable {
		let name: String
		let size: Int
		/// The file's modification date, which a play sets when it touches the file.
		let lastUsed: Date
	}

	/// The share of the budget the cache is trimmed to once it is exceeded, so a long
	/// queue does not prune after every play.
	static let trimFraction = 0.8

	/// When the cache is measured and how much it may hold.
	struct Limits {
		let budgetBytes: Int
		let maxAge: TimeInterval
		let now: Date
	}

	/// Returns the entries to evict, in the order to delete them.
	///
	/// Files past `limits.maxAge` go first. Then, only when the remaining total still
	/// exceeds `limits.budgetBytes`, the least recently used outside `queueTrackIds` go
	/// before those inside it, until the total reaches `trimFraction` of the budget.
	/// Equally old entries go larger first, which frees the budget in fewer evictions.
	///
	/// A protected track is never evicted, and neither is a file whose name carries no
	/// track id — a half-written temporary download, or anything else the cache does not
	/// own. Both still count toward the total, so protecting a large queue degrades the
	/// cache rather than evicting a file that is about to play.
	static func evictions(
		entries: [Entry],
		protectedTrackIds: Set<Int>,
		queueTrackIds: Set<Int>,
		limits: Limits
	) -> [Entry] {
		let evictable = entries.filter { entry in
			guard let trackId = trackId(of: entry.name) else { return false }
			return !protectedTrackIds.contains(trackId)
		}

		var evicted: [Entry] = []
		var evictedNames = Set<String>()
		var total = entries.reduce(0) { $0 + $1.size }

		func remove(_ entry: Entry) {
			evicted.append(entry)
			evictedNames.insert(entry.name)
			total -= entry.size
		}

		for entry in evictable.sorted(by: oldestFirst) where limits.now.timeIntervalSince(entry.lastUsed) > limits.maxAge {
			remove(entry)
		}

		guard total > limits.budgetBytes else { return evicted }
		let target = Int(Double(limits.budgetBytes) * trimFraction)
		let remaining = evictable.filter { !evictedNames.contains($0.name) }
		let outsideQueue = remaining.filter { !isInQueue($0, queueTrackIds: queueTrackIds) }.sorted(by: oldestFirst)
		let inQueue = remaining.filter { isInQueue($0, queueTrackIds: queueTrackIds) }.sorted(by: oldestFirst)
		for entry in outsideQueue + inQueue where total > target {
			remove(entry)
		}
		return evicted
	}

	/// The track id a cache file name carries, or nil when it carries none.
	static func trackId(of name: String) -> Int? {
		let digits = name.prefix(while: \.isNumber)
		guard !digits.isEmpty, digits.count < name.count else { return nil }
		let separator = name[name.index(name.startIndex, offsetBy: digits.count)]
		guard separator == "-" else { return nil }
		return Int(digits)
	}

	/// Oldest first, ties broken by the larger file so fewer evictions free the budget.
	private static func oldestFirst(_ a: Entry, _ b: Entry) -> Bool {
		if a.lastUsed != b.lastUsed { return a.lastUsed < b.lastUsed }
		return a.size > b.size
	}

	private static func isInQueue(_ entry: Entry, queueTrackIds: Set<Int>) -> Bool {
		trackId(of: entry.name).map(queueTrackIds.contains) ?? false
	}
}
