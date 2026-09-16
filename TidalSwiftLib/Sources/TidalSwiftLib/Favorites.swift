//
//  Favorites.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

public class Favorites {
	unowned let session: Session
	var cache: FavoritesCache!
	let baseUrl: String

	public init(session: Session, userId: Int) {
		self.session = session
		self.baseUrl = "\(AuthInformation.APILocation)/users/\(userId)/favorites"
		self.cache = FavoritesCache(favorites: self)
	}

	// Return

	public func artists(limit: Int = 999, offset: Int = 0, order: ArtistOrder? = nil, orderDirection: OrderDirection? = nil) async -> [FavoriteArtist]? {
		let url = URL(string: "\(baseUrl)/artists")!
		var parameters = session.sessionParameters
		parameters["limit"] = "\(limit)"
		parameters["offset"] = "\(offset)"
		if let order = order {
			parameters["order"] = "\(order.rawValue)"
		}
		if let orderDirection = orderDirection {
			parameters["orderDirection"] = "\(orderDirection.rawValue)"
		}
		do {
			let response: FavoriteArtists = try await session.get(url: url, parameters: parameters)
			return response.items
		} catch {
			return nil
		}
	}

	public func albums(limit: Int = 999, offset: Int = 0, order: AlbumOrder? = nil, orderDirection: OrderDirection? = nil) async -> [FavoriteAlbum]? {
		let url = URL(string: "\(baseUrl)/albums")!
		var parameters = session.sessionParameters
		parameters["limit"] = "\(limit)"
		parameters["offset"] = "\(offset)"
		if let order = order {
			parameters["order"] = "\(order.rawValue)"
		}
		if let orderDirection = orderDirection {
			parameters["orderDirection"] = "\(orderDirection.rawValue)"
		}
		do {
			let response: FavoriteAlbums = try await session.get(url: url, parameters: parameters)
			return response.items
		} catch {
			return nil
		}
	}

	public func tracks(limit: Int = 999, offset: Int = 0, order: TrackOrder? = nil, orderDirection: OrderDirection? = nil) async -> [FavoriteTrack]? {
		let url = URL(string: "\(baseUrl)/tracks")!
		var parameters = session.sessionParameters
		parameters["limit"] = "\(limit)"
		parameters["offset"] = "\(offset)"
		if let order = order {
			parameters["order"] = "\(order.rawValue)"
		}
		if let orderDirection = orderDirection {
			parameters["orderDirection"] = "\(orderDirection.rawValue)"
		}
		do {
			let response: FavoriteTracks = try await session.get(url: url, parameters: parameters)
			return response.items
		} catch {
			return nil
		}
	}

	public func videos(limit: Int = 100, offset: Int = 0, order: VideoOrder? = nil, orderDirection: OrderDirection? = nil) async -> [FavoriteVideo]? {
		guard limit <= 100 else {
			displayError(title: "Favorite Videos failed (Limit too high)", content: "The limit has to be 100 or below.")
			return nil
		}

		let url = URL(string: "\(baseUrl)/videos")!
		var parameters = session.sessionParameters
		parameters["limit"] = "\(limit)" // Unlike the rest, here a maximum limit of 100 exists. Error if higher.
		parameters["offset"] = "\(offset)"
		if let order = order {
			parameters["order"] = "\(order.rawValue)"
		}
		if let orderDirection = orderDirection {
			parameters["orderDirection"] = "\(orderDirection.rawValue)"
		}
		do {
			let response: FavoriteVideos = try await session.get(url: url, parameters: parameters)
			return response.items
		} catch {
			return nil
		}
	}

	/// - Note: Includes User Playlists
	public func playlists(limit: Int = 999, offset: Int = 0, order: PlaylistOrder? = nil, orderDirection: OrderDirection? = nil) async -> [FavoritePlaylist]? {
		guard let userId = session.userId else {
			return nil
		}
		let url = URL(string: "\(AuthInformation.APILocation)/users/\(userId)/playlistsAndFavoritePlaylists")!

		var tempLimit = limit
		var tempOffset = offset
		var tempPlaylists: [FavoritePlaylist] = []
		while tempLimit > 0 {
//			print("tempLimit: \(tempLimit), tempOffset: \(tempOffset)")
			var parameters = session.sessionParameters
			if tempLimit > 50 { // Maximum of 50 allowed by Tidal
				parameters["limit"] = "50"
			} else {
				parameters["limit"] = "\(tempLimit)"
			}
			parameters["offset"] = "\(tempOffset)"
			if let order = order {
				parameters["order"] = "\(order.rawValue)"
			}
			if let orderDirection = orderDirection {
				parameters["orderDirection"] = "\(orderDirection.rawValue)"
			}
			do {
				let response: FavoritePlaylists = try await session.get(url: url, parameters: parameters)
				// TODO: JSON signature is different

				tempPlaylists += response.items

				if response.totalNumberOfItems - tempOffset < tempLimit {
					return tempPlaylists
				}

				tempLimit -= 50
				tempOffset += 50
			} catch {
				return nil
			}
		}

		return tempPlaylists
	}

	/// - Note: Only includes User Favorited Playlists, unlike `playlists()`, which also includes User Playlists.
	public func favoritedPlaylists(limit: Int = 999, offset: Int = 0, order: PlaylistOrder? = nil, orderDirection: OrderDirection? = nil) async -> [Playlist]? {
		guard let userId = session.userId else {
			return nil
		}
		let url = URL(string: "\(AuthInformation.APILocation)/users/\(userId)/favorites/playlists")!

		var tempLimit = limit
		var tempOffset = offset
		var tempPlaylists: [Playlist] = []
		while tempLimit > 0 {
			var parameters = session.sessionParameters
			if tempLimit > 50 { // Maximum of 50 allowed by Tidal
				parameters["limit"] = "50"
			} else {
				parameters["limit"] = "\(tempLimit)"
			}
			parameters["offset"] = "\(tempOffset)"
			if let order = order {
				parameters["order"] = "\(order.rawValue)"
			}
			if let orderDirection = orderDirection {
				parameters["orderDirection"] = "\(orderDirection.rawValue)"
			}
			do {
				let response: FavoritePlaylistsOnly = try await session.get(url: url, parameters: parameters)
				tempPlaylists += response.items.map(\.item)

				tempOffset += response.items.count
				tempLimit -= response.items.count

				if response.items.isEmpty || tempOffset >= response.totalNumberOfItems {
					return tempPlaylists
				}
			} catch {
				return nil
			}
		}

		return tempPlaylists
	}

	public func userPlaylists() async -> [Playlist]? {
		guard let userId = session.userId else {
			displayError(title: "User Playlists failed", content: "User ID not set yet.")
			return nil
		}

		return await session.userPlaylists(userId: userId)
	}

	// Add

	@discardableResult public func addArtist(artistId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/artists")!
		var parameters = session.sessionParameters
		parameters["artistIds"] = "\(artistId)"
		do {
			_ = try await session.post(url: url, parameters: parameters)
			await refreshCachedArtists()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func addAlbum(albumId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/albums")!
		var parameters = session.sessionParameters
		parameters["albumIds"] = "\(albumId)"
		do {
			_ = try await session.post(url: url, parameters: parameters)
			await refreshCachedAlbums()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func addTrack(trackId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/tracks")!
		var parameters = session.sessionParameters
		parameters["trackIds"] = "\(trackId)"
		do {
			_ = try await session.post(url: url, parameters: parameters)
			await refreshCachedTracks()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func addVideo(videoId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/videos")!
		var parameters = session.sessionParameters
		parameters["videoIds"] = "\(videoId)"
		do {
			_ = try await session.post(url: url, parameters: parameters)
			await refreshCachedVideos()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func addPlaylist(playlistId: String) async -> Bool {
		let url = URL(string: "\(baseUrl)/playlists")!
		var parameters = session.sessionParameters
		parameters["uuids"] = playlistId
		do {
			_ = try await session.post(url: url, parameters: parameters)
			await refreshCachedPlaylists()
			return true
		} catch {
			return false
		}
	}

	// Delete

	@discardableResult public func removeArtist(artistId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/artists/\(artistId)")!
		do {
			_ = try await session.delete(url: url, parameters: session.sessionParameters)
			await refreshCachedArtists()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func removeAlbum(albumId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/albums/\(albumId)")!
		do {
			_ = try await session.delete(url: url, parameters: session.sessionParameters)
			await refreshCachedAlbums()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func removeTrack(trackId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/tracks/\(trackId)")!
		do {
			_ = try await session.delete(url: url, parameters: session.sessionParameters)
			await refreshCachedTracks()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func removeVideo(videoId: Int) async -> Bool {
		let url = URL(string: "\(baseUrl)/videos/\(videoId)")!
		do {
			_ = try await session.delete(url: url, parameters: session.sessionParameters)
			await refreshCachedVideos()
			return true
		} catch {
			return false
		}
	}

	@discardableResult public func removePlaylist(playlistId: String) async -> Bool {
		let url = URL(string: "\(baseUrl)/playlists/\(playlistId)")!
		do {
			_ = try await session.delete(url: url, parameters: session.sessionParameters)
			await refreshCachedPlaylists()
			return true
		} catch {
			return false
		}
	}

	// Check

	public func doFavoritesContainArtist(artistId: Int) async -> Bool? {
		await cache.containsArtist(artistId)
	}

	public func doFavoritesContainAlbum(albumId: Int) async -> Bool? {
		await cache.containsAlbum(albumId)
	}

	public func doFavoritesContainTrack(trackId: Int) async -> Bool? {
		await cache.containsTrack(trackId)
	}

	public func doFavoritesContainVideo(videoId: Int) async -> Bool? {
		await cache.containsVideo(videoId)
	}

	public func doFavoritesContainPlaylist(playlistId: String) async -> Bool? {
		await cache.containsPlaylist(playlistId)
	}

	// Refresh Caches

	private func refreshCachedArtists() async {
		cache.set(await artists())
	}

	private func refreshCachedAlbums() async {
		cache.set(await albums())
	}

	private func refreshCachedTracks() async {
		cache.set(await tracks())
	}

	private func refreshCachedVideos() async {
		cache.set(await videos())
	}

	private func refreshCachedPlaylists() async {
		cache.set(await playlists())
	}
}

class FavoritesCache {
	unowned let favorites: Favorites
	let timeoutInSeconds: Double

	init(favorites: Favorites, timeoutInSeconds: Double = 60) {
		self.favorites = favorites
		self.timeoutInSeconds = timeoutInSeconds
	}

	private var _artists: [FavoriteArtist]?
	private var artistIds: Set<Int> = []
	private var lastCheckedArtists = Date(timeIntervalSince1970: 0)
	private var artistsRefreshTask: Task<Void, Never>?

	var artists: [FavoriteArtist]? {
		get async {
			if Date().timeIntervalSince(lastCheckedArtists) > timeoutInSeconds {
				if let artistsRefreshTask {
					await artistsRefreshTask.value
				} else {
					let task = Task {
						defer { artistsRefreshTask = nil }
						set(await favorites.artists())
					}
					artistsRefreshTask = task
					await task.value
				}
			}
			return _artists
		}
	}
	func set(_ newValue: [FavoriteArtist]?) {
		_artists = newValue
		artistIds = Set(newValue?.map { $0.item.id } ?? [])
		lastCheckedArtists = .now
	}
	func containsArtist(_ artistId: Int) async -> Bool? {
		guard await artists != nil else {
			return nil
		}
		return artistIds.contains(artistId)
	}

	private var _albums: [FavoriteAlbum]?
	private var albumIds: Set<Int> = []
	private var lastCheckedAlbums = Date(timeIntervalSince1970: 0)
	private var albumsRefreshTask: Task<Void, Never>?

	var albums: [FavoriteAlbum]? {
		get async {
			if Date().timeIntervalSince(lastCheckedAlbums) > timeoutInSeconds {
				if let albumsRefreshTask {
					await albumsRefreshTask.value
				} else {
					let task = Task {
						defer { albumsRefreshTask = nil }
						set(await favorites.albums())
					}
					albumsRefreshTask = task
					await task.value
				}
			}
			return _albums
		}
	}
	func set(_ newValue: [FavoriteAlbum]?) {
		_albums = newValue
		albumIds = Set(newValue?.map { $0.item.id } ?? [])
		lastCheckedAlbums = .now
	}
	func containsAlbum(_ albumId: Int) async -> Bool? {
		guard await albums != nil else {
			return nil
		}
		return albumIds.contains(albumId)
	}

	private var _tracks: [FavoriteTrack]?
	private var trackIds: Set<Int> = []
	private var lastCheckedTracks = Date(timeIntervalSince1970: 0)
	private var tracksRefreshTask: Task<Void, Never>?

	var tracks: [FavoriteTrack]? {
		get async {
			if Date().timeIntervalSince(lastCheckedTracks) > timeoutInSeconds {
				if let tracksRefreshTask {
					await tracksRefreshTask.value
				} else {
					let task = Task {
						defer { tracksRefreshTask = nil }
						set(await favorites.tracks())
					}
					tracksRefreshTask = task
					await task.value
				}
			}
			return _tracks
		}
	}
	func set(_ newValue: [FavoriteTrack]?) {
		_tracks = newValue
		trackIds = Set(newValue?.map { $0.item.id } ?? [])
		lastCheckedTracks = .now
	}
	func containsTrack(_ trackId: Int) async -> Bool? {
		guard await tracks != nil else {
			return nil
		}
		return trackIds.contains(trackId)
	}

	private var _videos: [FavoriteVideo]?
	private var videoIds: Set<Int> = []
	private var lastCheckedVideos = Date(timeIntervalSince1970: 0)
	private var videosRefreshTask: Task<Void, Never>?

	var videos: [FavoriteVideo]? {
		get async {
			if Date().timeIntervalSince(lastCheckedVideos) > timeoutInSeconds {
				if let videosRefreshTask {
					await videosRefreshTask.value
				} else {
					let task = Task {
						defer { videosRefreshTask = nil }
						set(await favorites.videos())
					}
					videosRefreshTask = task
					await task.value
				}
			}
			return _videos
		}
	}
	func set(_ newValue: [FavoriteVideo]?) {
		_videos = newValue
		videoIds = Set(newValue?.map { $0.item.id } ?? [])
		lastCheckedVideos = .now
	}
	func containsVideo(_ videoId: Int) async -> Bool? {
		guard await videos != nil else {
			return nil
		}
		return videoIds.contains(videoId)
	}

	private var _playlists: [FavoritePlaylist]?
	private var playlistIds: Set<String> = []
	private var lastCheckedPlaylists = Date(timeIntervalSince1970: 0)
	private var playlistsRefreshTask: Task<Void, Never>?

	var playlists: [FavoritePlaylist]? {
		get async {
			if Date().timeIntervalSince(lastCheckedPlaylists) > timeoutInSeconds {
				if let playlistsRefreshTask {
					await playlistsRefreshTask.value
				} else {
					let task = Task {
						defer { playlistsRefreshTask = nil }
						set(await favorites.playlists())
					}
					playlistsRefreshTask = task
					await task.value
				}
			}
			return _playlists
		}
	}
	func set(_ newValue: [FavoritePlaylist]?) {
		_playlists = newValue
		playlistIds = Set(newValue?.map { $0.playlist.id } ?? [])
		lastCheckedPlaylists = .now
	}
	func containsPlaylist(_ playlistId: String) async -> Bool? {
		guard await playlists != nil else {
			return nil
		}
		return playlistIds.contains(playlistId)
	}
}
