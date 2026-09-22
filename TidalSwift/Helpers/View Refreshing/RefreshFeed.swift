//
//  RefreshFeed.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib
import os

extension ViewState {
	/// Loads the Feed: the v2 activity feed when it has items, otherwise the
	/// newest releases of the user's favourite artists.
	func feed() {
		var view = TidalSwiftView(viewType: .feed)
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshFeed()
		}
	}

	private func refreshFeed() async {
		let activities = await session.feedActivities()

		guard !Task.isCancelled else { return }
		Logger(subsystem: "io.hosh.TidalSwift", category: "feed")
			.error("REFRESH feed activities=\(activities?.count ?? -1, privacy: .public)")

		// Unknown activity types and payloads that failed to decode can't be
		// rendered, so only a displayable list counts as feed content.
		let displayable = activities?.filter(\.isDisplayable) ?? []
		let feedFailed = activities == nil

		var view = TidalSwiftView(viewType: .feed)

		if !displayable.isEmpty {
			cache.feedActivities = displayable
			cache.feedReleases = nil
			view.loadingState = .successful
		} else if feedFailed, let cached = cache.feedActivities, !cached.isEmpty {
			// Keep the cached activities rather than replacing them with the
			// fallback after a failed refresh.
			view.loadingState = .successful
		} else {
			let maxQuality = UserDefaults.standard.string(forKey: "audioQuality").flatMap(AudioQuality.init(rawValue:))
			let releases = await session.helpers.newReleasesFromFavouriteArtists(maxQuality: maxQuality)

			guard !Task.isCancelled else { return }
			if let releases {
				cache.feedReleases = releases
				if !feedFailed {
					// The server answered with nothing displayable, so cached
					// activities are stale.
					cache.feedActivities = nil
				}
				view.loadingState = .successful
			} else if cache.feedActivities != nil || cache.feedReleases != nil {
				// Keep the cached content rather than dropping to an error.
				view.loadingState = .successful
			} else {
				view.loadingState = .error
			}
		}

		replaceCurrentView(with: view)
	}
}
