//
//  RefreshAllPlaylists.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 15.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import Foundation
import TidalSwiftLib

extension ViewState {
	/// Merges the user's own playlists with their favourited playlists, deduped by uuid.
	/// Writes the result to `cache.allPlaylists` and returns it; the sidebar keeps its own
	/// `@State` copy because `cache` is not `@Published`.
	///
	/// `favorites.playlists()` returns user-created and user-favourited playlists combined,
	/// so the favourited uuids are fetched separately from the favourites-only endpoint to
	/// drive the sidebar heart.
	func refreshAllPlaylists() async -> (playlists: [Playlist], favoritedUuids: Set<String>) {
		guard let userId = session.userId else {
			return (cache.allPlaylists ?? [], cache.favoritedPlaylistUuids ?? [])
		}

		let ownedResult = await session.userPlaylists(userId: userId)

		var favoritePlaylists: [FavoritePlaylist]?
		var favoritedOnlyPlaylists: [Playlist]?
		if let favorites = session.favorites {
			favoritePlaylists = await favorites.playlists(order: .dateAdded, orderDirection: .descending)
			favoritedOnlyPlaylists = await favorites.favoritedPlaylists(order: .dateAdded, orderDirection: .descending)
		}

		// Only overwrite the cache when at least one request succeeded; a transient
		// failure (nil) must not wipe the sidebar.
		guard ownedResult != nil || favoritePlaylists != nil else {
			return (cache.allPlaylists ?? [], cache.favoritedPlaylistUuids ?? [])
		}

		let owned = ownedResult ?? []
		let favorited = favoritePlaylists?.unwrapped() ?? []

		// The combined endpoint's `type` can't express "created and favourited", so the
		// favourites-only endpoint is the source of truth for the heart. If it failed, fall
		// back to the old `type` filter; if that failed too, keep the previous hearts.
		let favoritedUuids: Set<String>
		if let favoritedOnlyPlaylists {
			favoritedUuids = Set(favoritedOnlyPlaylists.map(\.uuid))
		} else if let favoritePlaylists {
			favoritedUuids = Set(favoritePlaylists.filter { $0.type == .userFavorited }.map(\.playlist.uuid))
		} else {
			favoritedUuids = cache.favoritedPlaylistUuids ?? []
		}

		var seen = Set<String>()
		var merged: [Playlist] = []
		for playlist in owned + favorited where seen.insert(playlist.uuid).inserted {
			merged.append(playlist)
		}

		cache.allPlaylists = merged
		cache.favoritedPlaylistUuids = favoritedUuids
		return (merged, favoritedUuids)
	}
}
