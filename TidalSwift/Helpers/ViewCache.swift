//
//  ViewCache.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 26.11.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation
import TidalSwiftLib

/// A favourite track with its date added, as stored in `ViewCache`.
///
/// The lib's `FavoriteTrack` is decode-only, so it can't be encoded into the
/// persisted cache; this is its Codable twin for the app target.
struct CollectionTrackEntry: Codable, Identifiable {
	var id: Int { track.id }
	let track: Track
	let created: Date
}

struct ViewCache: Codable {
	var searchResponses: [String: SearchResponse] = [:]

	var homeFeedForYou: HomeFeedV2?
	var homeFeedStaffPicks: HomeFeedV2?
	var homeFeedUploads: HomeFeedV2?

	/// The Explore hub (`pages/explore`).
	var explorePage: Page?
	/// v1 pages keyed by their relative path.
	var pages: [String: Page] = [:]

	/// The v2 activity feed, limited to the activities this build can display.
	/// `nil` until something displayable has been loaded.
	var feedActivities: [FeedActivity]?
	/// Fallback shown when the activity feed is empty: the newest releases of
	/// the user's favourite artists.
	var feedReleases: [Album]?

	var favoriteArtists: [Artist]?
	var favoriteAlbums: [Album]?
	var favoritePlaylists: [Playlist]?
	var favoriteTracks: [Track]?
	var favoriteVideos: [Video]?

	var allPlaylists: [Playlist]?
	/// Uuids of the favourited subset of `allPlaylists` (which also holds user-created playlists).
	var favoritedPlaylistUuids: Set<String>?

	/// The Collection ▸ Mixes & Radio list and the cursor of the page it came
	/// from. Optional so previously saved caches still decode.
	var collectionMixes: [MixesItem]?
	var collectionMixesCursor: String?

	/// The Collection ▸ Tracks favourites, kept as entries so each row can show
	/// its date added. Optional so previously saved caches still decode.
	var collectionTracks: [CollectionTrackEntry]?

//	var artist: [Int: Artist] = [:]
//	var album: [Int: Album] = [:]
//	var playlist: [String: Playlist] = [:]
//	var video: [Int: Video] = [:]

	var mixTracks: [String: [Track]] = [:]
	var artistTopTracks: [Int: [Track]] = [:]
	var artistAlbums: [Int: [Album]] = [:]
	var artistAlbumsEpsAndSingles: [Int: [Album]] = [:]
	var artistAlbumsAppearances: [Int: [Album]] = [:]
	var artistVideos: [Int: [Video]] = [:]
	var albumTracks: [Int: [Track]] = [:]
	var playlistTracks: [String: [Track]] = [:]
}

extension ViewCache {
	func homeFeed(for tab: MusicTab) -> HomeFeedV2? {
		switch tab {
		case .forYou:
			return homeFeedForYou
		case .staffPicks:
			return homeFeedStaffPicks
		case .uploads:
			return homeFeedUploads
		}
	}

	mutating func setHomeFeed(_ feed: HomeFeedV2, for tab: MusicTab) {
		switch tab {
		case .forYou:
			homeFeedForYou = feed
		case .staffPicks:
			homeFeedStaffPicks = feed
		case .uploads:
			homeFeedUploads = feed
		}
	}
}
