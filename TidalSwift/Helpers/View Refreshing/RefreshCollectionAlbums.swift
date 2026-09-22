//
//  RefreshCollectionAlbums.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib

extension ViewState {
	func collectionAlbums() {
		let viewType = collectionViewType(.collectionAlbums, legacy: .favoriteAlbums)
		var view = TidalSwiftView(viewType: viewType)
		view.albums = cache.favoriteAlbums
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshCollectionAlbums()
		}
	}

	private func refreshCollectionAlbums() async {
		let viewType = collectionViewType(.collectionAlbums, legacy: .favoriteAlbums)
		var view = TidalSwiftView(viewType: viewType)
		guard let favorites = session.favorites else {
			guard !Task.isCancelled else { return }
			view.albums = cache.favoriteAlbums
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}
		guard let favA = await favorites.albums(order: .dateAdded, orderDirection: .descending) else {
			guard !Task.isCancelled else { return }
			view.albums = cache.favoriteAlbums
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}

		guard !Task.isCancelled else { return }
		let albums = favA.unwrapped()

		view.albums = albums
		view.loadingState = .successful
		cache.favoriteAlbums = albums

		replaceCurrentView(with: view)
	}
}
