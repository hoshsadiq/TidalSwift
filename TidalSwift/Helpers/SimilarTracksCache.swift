//
//  SimilarTracksCache.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib

/// In-memory cache for the Similar tracks panel, keyed by track id.
///
/// The panel is torn down when the drawer's panel closes, so the cache lives
/// outside the view to make re-opening the panel for the same track instant.
@MainActor
final class SimilarTracksCache {
	static let shared = SimilarTracksCache()

	final class Entry {
		let mixes: [MixesItem]
		let suggestions: [Track]

		init(mixes: [MixesItem], suggestions: [Track]) {
			self.mixes = mixes
			self.suggestions = suggestions
		}
	}

	private let cache = NSCache<NSNumber, Entry>()

	private init() {
		cache.countLimit = 20
	}

	func entry(for trackId: Int) -> Entry? {
		cache.object(forKey: NSNumber(value: trackId))
	}

	func store(_ entry: Entry, for trackId: Int) {
		cache.setObject(entry, forKey: NSNumber(value: trackId))
	}
}
