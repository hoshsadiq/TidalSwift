//
//  RefreshCollectionPlaylists.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib

extension ViewState {
	func collectionPlaylists() {
		let viewType = collectionViewType(.collectionPlaylists, legacy: .favoritePlaylists)
		var view = TidalSwiftView(viewType: viewType)
		view.playlists = cache.allPlaylists
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshCollectionPlaylists()
		}
	}

	private func refreshCollectionPlaylists() async {
		let viewType = collectionViewType(.collectionPlaylists, legacy: .favoritePlaylists)
		var view = TidalSwiftView(viewType: viewType)
		// Same source as the sidebar's "All playlists": owned + favourited, deduped.
		let result = await refreshAllPlaylists()
		guard !Task.isCancelled else { return }
		view.playlists = result.playlists
		view.loadingState = .successful
		replaceCurrentView(with: view)
	}
}
