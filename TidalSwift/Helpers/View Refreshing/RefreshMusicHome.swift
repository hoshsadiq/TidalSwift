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
		var view = TidalSwiftView(viewType: .music)
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshMusicHome()
		}
	}

	// Stub: the Music tab home page content will be added here.
	private func refreshMusicHome() async {
		guard !Task.isCancelled else { return }
		var view = TidalSwiftView(viewType: .music)
		view.loadingState = .successful
		replaceCurrentView(with: view)
	}
}
