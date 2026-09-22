//
//  RefreshCollectionTracks.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib

extension ViewState {
	func collectionTracks() {
		let viewType = collectionViewType(.collectionTracks, legacy: .favoriteTracks)
		var view = TidalSwiftView(viewType: viewType)
		view.tracks = cache.favoriteTracks
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshCollectionTracks()
		}
	}

	private func refreshCollectionTracks() async {
		let viewType = collectionViewType(.collectionTracks, legacy: .favoriteTracks)
		var view = TidalSwiftView(viewType: viewType)
		guard let favorites = session.favorites else {
			guard !Task.isCancelled else { return }
			view.tracks = cache.favoriteTracks
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}
		guard let favT = await favorites.tracks(order: .dateAdded, orderDirection: .descending) else {
			guard !Task.isCancelled else { return }
			view.tracks = cache.favoriteTracks
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}

		guard !Task.isCancelled else { return }
		let tracks = favT.unwrapped()

		view.tracks = tracks
		view.loadingState = .successful
		cache.favoriteTracks = tracks
		// Keep the envelope too: the Tracks table shows each favourite's date added.
		cache.collectionTracks = favT.map { CollectionTrackEntry(track: $0.item, created: $0.created) }

		session.helpers.offline.asyncSyncFavoriteTracks()
		replaceCurrentView(with: view)
	}
}
