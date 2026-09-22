//
//  Playlist.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

public enum PlaylistOrder: String {
	case dateAdded = "DATE"
	case name = "NAME"
}

extension Session {
	public func playlist(playlistId: String) async -> Playlist? {
		let url = URL(string: "\(AuthInformation.APILocation)/playlists/\(playlistId)")!
		do {
			let response: Playlist = try await get(url: url, parameters: sessionParameters)
			return response
		} catch {
			return nil
		}
	}

	public func playlistTracks(playlistId: String) async -> [Track]? {
		let url = URL(string: "\(AuthInformation.APILocation)/playlists/\(playlistId)/tracks")!
		do {
			let response: Tracks = try await get(url: url, parameters: sessionParameters)
			return response.items
		} catch {
			return nil
		}
	}

	/// Fetches up to `limit` cover image ids from a playlist's items, for the
	/// 4-tile mosaic artwork.
	///
	/// The v1 items route wraps each entry in `{cut, item, type}`; the tile
	/// image id is `item.album.cover`. Returns `nil` on any failure.
	public func playlistArtworkTiles(playlistId: String, limit: Int = 4) async -> [String]? {
		var parameters = sessionParameters
		parameters["limit"] = String(limit)
		parameters["offset"] = "0"
		let url = URL(string: "\(AuthInformation.APILocation)/playlists/\(playlistId)/items")!
		do {
			let response: PlaylistItemsPage = try await get(url: url, parameters: parameters)
			return Array(response.items.compactMap { $0.item?.album.cover }.prefix(limit))
		} catch {
			return nil
		}
	}
}
