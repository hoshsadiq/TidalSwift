//
//  RefreshMusicHome.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 15.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import Foundation
import TidalSwiftLib

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
		let page = await page(for: tab)

		guard !Task.isCancelled else { return }
		var view = TidalSwiftView(viewType: .music)
		if let page {
			view.loadingState = .successful
			cache.setHomePage(page, for: tab)
		} else {
			view.loadingState = .error
		}

		replaceCurrentView(with: view)
	}

	private func page(for tab: MusicTab) async -> Page? {
		guard let path = tab.path else {
			return await spotlightedUploadsPage()
		}
		return await session.page(path: path)
	}

	/// `pages/uploads` and `pages/spotlighted_uploads` both return 404. The only
	/// uploads feed Tidal exposes is the "Spotlighted Uploads" module on the home
	/// page, so resolve its `showMore` path and fetch that single-module page.
	private func spotlightedUploadsPage() async -> Page? {
		guard let home = await session.page(path: "pages/home"),
			  let path = home.modules.first(where: { $0.title == "Spotlighted Uploads" })?.showMore?.apiPath
		else { return nil }
		return await session.page(path: path)
	}
}
