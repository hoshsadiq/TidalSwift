//
//  RefreshMusicHome.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 15.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import Foundation
import TidalSwiftLib
import os

extension ViewState {
	func music() {
		music(tab: .forYou)
	}

	func music(tab: MusicTab) {
		var view = TidalSwiftView(viewType: .music)
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshMusicHome(tab: tab)
		}
	}

	private func refreshMusicHome(tab: MusicTab) async {
		let feed = await homeFeed(for: tab)

		guard !Task.isCancelled else { return }
		Logger(subsystem: "de.melgu.TidalSwift", category: "magazine")
			.error("REFRESH tab=\(tab.rawValue, privacy: .public) feedNil=\(feed == nil, privacy: .public) modules=\(feed?.items.count ?? -1, privacy: .public)")
		var view = TidalSwiftView(viewType: .music)
		if let feed {
			view.loadingState = .successful
			cache.setHomeFeed(feed, for: tab)
		} else {
			view.loadingState = .error
		}

		replaceCurrentView(with: view)
	}

	/// Fetches the v2 home feed for a tab, following `page.cursor` and
	/// concatenating the remaining pages into one feed.
	///
	/// Stops when the cursor is `nil`, repeats a previous value, or after 5
	/// pages. The concatenated feed keeps page 1's `uuid`, `page` and `header`;
	/// its `items` are all pages' modules in order. This is what brings in the
	/// "Spotlighted Uploads" and "Your listening history" sections.
	private func homeFeed(for tab: MusicTab) async -> HomeFeedV2? {
		guard let first = await session.homeFeed(slug: tab.slug) else { return nil }

		var modules = first.items
		var cursor = first.page?.cursor
		var seenCursors: Set<String> = []
		var pageCount = 1

		while let current = cursor, !seenCursors.contains(current), pageCount < 5 {
			guard !Task.isCancelled else { break }
			seenCursors.insert(current)
			guard let next = await session.homeFeed(slug: tab.slug, cursor: current) else { break }
			modules.append(contentsOf: next.items)
			cursor = next.page?.cursor
			pageCount += 1
		}

		return HomeFeedV2(uuid: first.uuid, page: first.page, header: first.header, items: modules)
	}
}
