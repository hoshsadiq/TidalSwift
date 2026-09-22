//
//  RefreshCollectionProfiles.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib

extension ViewState {
	func collectionProfiles() {
		let viewType = collectionViewType(.collectionProfiles, legacy: .favoriteArtists)
		var view = TidalSwiftView(viewType: viewType)
		view.artists = cache.favoriteArtists
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshCollectionProfiles()
		}
	}

	private func refreshCollectionProfiles() async {
		let viewType = collectionViewType(.collectionProfiles, legacy: .favoriteArtists)
		var view = TidalSwiftView(viewType: viewType)
		guard let favorites = session.favorites else {
			guard !Task.isCancelled else { return }
			view.artists = cache.favoriteArtists
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}
		guard let favA = await favorites.artists(order: .dateAdded, orderDirection: .descending) else {
			guard !Task.isCancelled else { return }
			view.artists = cache.favoriteArtists
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}

		guard !Task.isCancelled else { return }
		let artists = favA.unwrapped()

		view.artists = artists
		view.loadingState = .successful
		cache.favoriteArtists = artists

		replaceCurrentView(with: view)
	}
}
