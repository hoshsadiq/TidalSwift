//
//  RefreshCollectionVideos.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib

extension ViewState {
	func collectionVideos() {
		let viewType = collectionViewType(.collectionVideos, legacy: .favoriteVideos)
		var view = TidalSwiftView(viewType: viewType)
		view.videos = cache.favoriteVideos
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshCollectionVideos()
		}
	}

	private func refreshCollectionVideos() async {
		let viewType = collectionViewType(.collectionVideos, legacy: .favoriteVideos)
		var view = TidalSwiftView(viewType: viewType)
		guard let favorites = session.favorites else {
			guard !Task.isCancelled else { return }
			view.videos = cache.favoriteVideos
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}
		guard let favV = await favorites.videos(order: .dateAdded, orderDirection: .descending) else {
			guard !Task.isCancelled else { return }
			view.videos = cache.favoriteVideos
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}

		guard !Task.isCancelled else { return }
		let videos = favV.unwrapped()

		view.videos = videos
		view.loadingState = .successful
		cache.favoriteVideos = videos

		replaceCurrentView(with: view)
	}
}
