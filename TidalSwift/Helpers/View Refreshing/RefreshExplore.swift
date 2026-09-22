//
//  RefreshExplore.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib
import os

extension ViewState {
	/// Loads the Explore hub (`pages/explore`), mirroring `music()`.
	func explore() {
		var view = TidalSwiftView(viewType: .explore)
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshExplore()
		}
	}

	private func refreshExplore() async {
		let page = await session.page(path: "pages/explore")

		guard !Task.isCancelled else { return }
		Logger(subsystem: "io.hosh.TidalSwift", category: "explore")
			.error("REFRESH explore pageNil=\(page == nil, privacy: .public) modules=\(page?.modules.count ?? -1, privacy: .public)")

		var view = TidalSwiftView(viewType: .explore)
		if let page {
			view.loadingState = .successful
			cache.explorePage = page
		} else {
			view.loadingState = .error
		}

		replaceCurrentView(with: view)
	}
}
