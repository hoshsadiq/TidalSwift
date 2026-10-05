//
//  Offline.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 12.12.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI

// MARK: DB

public final class OfflineDB {
	/// All tracks needed offline. Derived from the favorites, albums and playlists instead of stored,
	/// so a track is kept exactly as long as one of them still contains it.
	private(set) var tracks: Set<Track> = []

	private func updateTracks() {
		let albumTracks = albums.flatMap { self.albumTracks[$0] ?? [] }
		let playlistTracks = playlists.flatMap { self.playlistTracks[$0] ?? [] }
		let newTracks = Set((favoriteTracks + standaloneOfflineTracks + albumTracks + playlistTracks).filter(\.isPlayable))

		// The dates are only touched once the persisted state is loaded, so a
		// half-loaded db can't wipe a date for a track it simply hasn't read yet.
		if isLoaded {
			let newIds = Set(newTracks.map(\.id))
			for id in newIds.subtracting(previouslyTrackedIds) {
				recordAddedDate(for: id)
			}
			for id in previouslyTrackedIds.subtracting(newIds) {
				trackAddedDates[id] = nil
			}
		}
		previouslyTrackedIds = Set(newTracks.map(\.id))
		tracks = newTracks
	}

	private var previouslyTrackedIds: Set<Int> = []
	private var isLoaded = false

	// [TrackId: DateAddedToOffline]
	// Persisted by the adjacent `tracks` derivation's save(); always changed together with it.
	private(set) var trackAddedDates: [Int: Date] = [:]
	func recordAddedDate(for trackId: Int) {
		guard trackAddedDates[trackId] == nil else { return }
		trackAddedDates[trackId] = Date()
	}

	private(set) var favoriteTracks: [Track] = [] { // Used for Favorites
		didSet {
			updateTracks()
			save()
		}
	}
	fileprivate func setFavoriteTracks(to tracks: [Track]) {
		favoriteTracks = tracks
	}

	fileprivate var albums: [Album] = [] {
		didSet {
			updateTracks()
			save()
		}
	}
	fileprivate func add(_ album: Album) {
		albums.append(album)
	}
	fileprivate func remove(_ album: Album) {
		albums.removeAll(where: { $0 == album })
	}

	fileprivate var albumTracks: [Album: [Track]] = [:] {
		didSet {
			updateTracks()
			save()
		}
	}
	fileprivate func setTracks(for album: Album, to tracks: [Track]?) {
		albumTracks[album] = tracks
	}

	fileprivate var playlists: [Playlist] = [] {
		didSet {
			updateTracks()
			save()
		}
	}
	fileprivate func add(_ playlist: Playlist) {
		playlists.append(playlist)
	}
	fileprivate func remove(_ playlist: Playlist) {
		playlists.removeAll(where: { $0 == playlist })
	}

	fileprivate var playlistTracks: [Playlist: [Track]] = [:] {
		didSet {
			updateTracks()
			save()
		}
	}
	fileprivate func setTracks(for playlist: Playlist, to tracks: [Track]?) {
		playlistTracks[playlist] = tracks
	}

	/// Tracks pinned individually from the track context menu, independent of
	/// favourites, albums and playlists. Stored as full records rather than ids:
	/// the sync needs a track's metadata to download it.
	private(set) var standaloneOfflineTracks: [Track] = [] {
		didSet {
			updateTracks()
			save()
		}
	}
	func addStandaloneOfflineTrack(_ track: Track) {
		guard !standaloneOfflineTracks.contains(track) else { return }
		standaloneOfflineTracks.append(track)
	}
	func removeStandaloneOfflineTrack(_ track: Track) {
		standaloneOfflineTracks.removeAll(where: { $0 == track })
	}

	init() {
		// Counters used before tracks were derived, which could drift and keep files forever
		UserDefaults.standard.removeObject(forKey: "OfflineDB:Tracks")

		if let data = UserDefaults.standard.data(forKey: "OfflineDB:TrackAddedDates") {
			if let temp = try? JSONDecoder().decode([Int: Date].self, from: data) {
				self.trackAddedDates = temp
			} else {
				self.trackAddedDates = [:]
			}
		}
		if let data = UserDefaults.standard.data(forKey: "OfflineDB:FavoriteTracks") {
			if let temp = try? JSONDecoder().decode([Track].self, from: data) {
				self.favoriteTracks = temp
			} else {
				self.favoriteTracks = []
			}
		}
		if let data = UserDefaults.standard.data(forKey: "OfflineDB:Albums") {
			if let temp = try? JSONDecoder().decode([Album].self, from: data) {
				self.albums = temp
			} else {
				self.albums = []
			}
		}
		if let data = UserDefaults.standard.data(forKey: "OfflineDB:AlbumTracks") {
			if let temp = try? JSONDecoder().decode([Album: [Track]].self, from: data) {
				self.albumTracks = temp
			} else {
				self.albumTracks = [:]
			}
		}
		if let data = UserDefaults.standard.data(forKey: "OfflineDB:Playlists") {
			if let temp = try? JSONDecoder().decode([Playlist].self, from: data) {
				self.playlists = temp
			} else {
				self.playlists = []
			}
		}
		if let data = UserDefaults.standard.data(forKey: "OfflineDB:PlaylistTracks") {
			if let temp = try? JSONDecoder().decode([Playlist: [Track]].self, from: data) {
				self.playlistTracks = temp
			} else {
				self.playlistTracks = [:]
			}
		}
		if let data = UserDefaults.standard.data(forKey: "OfflineDB:StandaloneOfflineTracks") {
			if let temp = try? JSONDecoder().decode([Track].self, from: data) {
				self.standaloneOfflineTracks = temp
			} else {
				self.standaloneOfflineTracks = []
			}
		}

		// Removals used to leave these behind
		let albums = self.albums
		let playlists = self.playlists
		self.albumTracks = self.albumTracks.filter { albums.contains($0.key) }
		self.playlistTracks = self.playlistTracks.filter { playlists.contains($0.key) }

		updateTracks()
		isLoaded = true
	}

	fileprivate func clear() {
		trackAddedDates = [:]
		favoriteTracks = []
		standaloneOfflineTracks = []
		albums = []
		albumTracks = [:]
		playlists = []
		playlistTracks = [:]
	}

	private func save() {
		let trackAddedDatesData = try? JSONEncoder().encode(trackAddedDates)
		UserDefaults.standard.set(trackAddedDatesData, forKey: "OfflineDB:TrackAddedDates")

		let favoriteTracksData = try? JSONEncoder().encode(favoriteTracks)
		UserDefaults.standard.set(favoriteTracksData, forKey: "OfflineDB:FavoriteTracks")

		let albumsData = try? JSONEncoder().encode(albums)
		UserDefaults.standard.set(albumsData, forKey: "OfflineDB:Albums")

		let albumTracksData = try? JSONEncoder().encode(albumTracks)
		UserDefaults.standard.set(albumTracksData, forKey: "OfflineDB:AlbumTracks")

		let playlistsData = try? JSONEncoder().encode(playlists)
		UserDefaults.standard.set(playlistsData, forKey: "OfflineDB:Playlists")

		let playlistTracksData = try? JSONEncoder().encode(playlistTracks)
		UserDefaults.standard.set(playlistTracksData, forKey: "OfflineDB:PlaylistTracks")

		let standaloneOfflineTracksData = try? JSONEncoder().encode(standaloneOfflineTracks)
		UserDefaults.standard.set(standaloneOfflineTracksData, forKey: "OfflineDB:StandaloneOfflineTracks")
	}
}

// MARK: - Offline

public final class Offline {
	private unowned let session: Session
	private let downloadStatus: DownloadStatus
	private let mainPath = "TidalSwift Offline Library"
	@MainActor
	public var uiRefreshFunc: () -> Void = {}

	@AppStorage("SaveFavoritesOffline") public var saveFavoritesOffline = false
	@AppStorage("offlinePreferDolbyAtmos") public private(set) var preferDolbyAtmos = false

	/// Dolby Atmos files are named "<track ID>.atmos.m4a", stereo files "<track ID>.<audio quality>.<extension>"
	private let dolbyAtmosFileMarker = "atmos"

	/// What a file on disk holds. The quality is nil for m4a files stored before it was part of the name.
	private enum FileVariant: Equatable {
		case dolbyAtmos
		case stereo(AudioQuality?)
	}

	private let db = OfflineDB()
	private var hydrationAttemptedAlbumIds: Set<Int> = []
	private let offlineLibraryRoot: URL?

	public init(session: Session, downloadStatus: DownloadStatus, offlineLibraryRoot: URL? = nil) {
		self.session = session
		self.downloadStatus = downloadStatus
		self.offlineLibraryRoot = offlineLibraryRoot

		// Create main folder if it doesn't exist
		do {
			var path = try offlineBaseURL()
			path.appendPathComponent(mainPath)
			if !FileManager.default.fileExists(atPath: path.relativePath) {
				print("Offline: Library Folder doesn't exist. Redownloading all Songs.")
				try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
			}
		} catch {
			displayError(title: "Offline: Error while creating Offline management class", content: "Error: \(error)")
		}

		Task { asyncSync() }
	}

	/// The folder that contains the offline library. `nil` root (the app) is the
	/// user's Music folder; tests pass a temporary directory so the background
	/// sync never touches the developer's real library.
	private func offlineBaseURL() throws -> URL {
		if let offlineLibraryRoot {
			return offlineLibraryRoot
		}
		return try FileManager.default.url(for: .musicDirectory,
										   in: .userDomainMask,
										   appropriateFor: nil,
										   create: false)
	}

	/// Resolves a path inside the offline library. Without `offlineLibraryRoot`
	/// this is the historical `<Music>/TidalSwift Offline Library` path; with one
	/// the supplied root replaces the Music folder, keeping `mainPath` as the
	/// final folder so the layout matches.
	private func offlinePath(parentFolder: String?, name: String, pathExtension: String?) -> URL? {
		guard let offlineLibraryRoot else {
			return buildPath(baseLocation: .music, parentFolder: parentFolder, name: name, pathExtension: pathExtension)
		}
		let root = offlineLibraryRoot.standardizedFileURL
		var path = root
		if let parentFolder, !parentFolder.isEmpty {
			path.appendPathComponent(parentFolder)
		}
		path.appendPathComponent(name)
		if let pathExtension {
			path.appendPathExtension(pathExtension)
		}
		guard path.standardizedFileURL.path.hasPrefix(root.path + "/") else {
			displayError(title: "Path Building Error", content: "Refusing to build path outside of offline library root: \(name)")
			return nil
		}
		return path
	}

	public func stream(for track: Track) async -> AudioStream? {
		if !db.tracks.contains(track) {
			return nil
		}
		guard let files = localFilesByTrackId()?[track.id], !files.isEmpty else {
			return nil
		}
		// An older variant can be left over, e.g. when removing it after a download failed
		let wantedVariant = wantedVariant(of: track)
		let url = files.first(where: { variant(of: $0, track: track) == wantedVariant }) ?? files[0]
		return AudioStream(url: url, pathExtension: url.pathExtension, isDolbyAtmos: variant(of: url, track: track) == .dolbyAtmos)
	}

	/// Changing it replaces offline files in other qualities on the next sync
	public func setAudioQuality(to audioQuality: AudioQuality) {
		guard audioQuality != session.config.offlineAudioQuality else { return }
		session.config.offlineAudioQuality = audioQuality
		session.saveConfig()
		asyncSync()
	}

	/// Changing it replaces offline files of tracks with Dolby Atmos on the next sync
	public func setPreferDolbyAtmos(to preferDolbyAtmos: Bool) {
		guard preferDolbyAtmos != self.preferDolbyAtmos else { return }
		self.preferDolbyAtmos = preferDolbyAtmos
		asyncSync()
	}

	/// Same choice as streaming, so offline playback sounds the same
	private func wantedVariant(of track: Track) -> FileVariant {
		if track.hasDolbyAtmos && (preferDolbyAtmos || !track.hasStereo) {
			return .dolbyAtmos
		}
		return .stereo(session.config.offlineAudioQuality)
	}

	private func variant(of url: URL, track: Track) -> FileVariant {
		let marker = url.deletingPathExtension().pathExtension
		// Atmos-only tracks were stored without the marker before, but can't be anything else
		if marker == dolbyAtmosFileMarker || (track.hasDolbyAtmos && !track.hasStereo) {
			return .dolbyAtmos
		}
		if let audioQuality = AudioQuality(rawValue: marker.uppercased()) {
			return .stereo(audioQuality)
		}
		// Only lossless comes as FLAC
		return .stereo(url.pathExtension == "flac" ? .high : nil)
	}

	private func variant(of stream: AudioStream) -> FileVariant {
		stream.isDolbyAtmos ? .dolbyAtmos : .stereo(session.config.offlineAudioQuality)
	}

	// The following always show the goal state (planned), i.e., after all downloads have finished
	public func numberOfOfflineTracks() async -> Int {
		db.tracks.count
	}
	public func allOfflineTracks() async -> [Track] {
		Array(db.tracks)
	}

	/// When the track was first added to offline. Downloads from before dates
	/// were recorded have none.
	public func addedDate(forTrackId trackId: Int) -> Date? {
		db.trackAddedDates[trackId]
	}

	public func numberOfOfflineAlbums() async -> Int {
		db.albums.count
	}
	public func allOfflineAlbums() async -> [Album] {
		db.albums
	}

	/// Returns the stored albums, rehydrating any that were saved without full
	/// metadata.
	///
	/// Albums added from a page or search response only carry `{id, title,
	/// cover, releaseDate}`, which leaves the Collection card without an artist
	/// and the context menu without its streaming actions. Each incomplete
	/// entry is refetched and the repair is persisted. A failed fetch keeps the
	/// stored entry, so a download is never dropped. The default skips ids
	/// already attempted this session (used by frequent reloads); `retryFailed`
	/// attempts them again, so a fresh screen entry can repair a failure.
	public func completeOfflineAlbums(retryFailed: Bool = false) async -> [Album] {
		var albums = db.albums
		var didChange = false
		for (index, album) in albums.enumerated() where album.streamReady == nil || album.artists == nil {
			if !retryFailed, hydrationAttemptedAlbumIds.contains(album.id) { continue }
			hydrationAttemptedAlbumIds.insert(album.id)
			guard let complete = await session.album(albumId: album.id) else { continue }
			albums[index] = complete
			didChange = true
		}
		if didChange {
			db.albums = albums
		}
		return db.albums
	}

	public func numberOfOfflinePlaylists() async -> Int {
		db.playlists.count
	}
	public func allOfflinePlaylists() async -> [Playlist] {
		db.playlists
	}

	public func isTrackMarkedForOffline(track: Track) async -> Bool {
		db.tracks.contains(track)
	}

	// MARK: - Track

	/// Pins a single track offline, independent of favourites, albums and playlists.
	public func add(track: Track) async {
		db.addStandaloneOfflineTrack(track)
		asyncSync()
	}

	/// Unpins a single track. It stays offline if a favourite, album or playlist still contains it.
	public func remove(track: Track) async {
		db.removeStandaloneOfflineTrack(track)
		asyncSync()
	}

	// Actual state

	/// Files on disk by track ID, whatever their extension, so files stay usable after the offline quality changes
	private func localFilesByTrackId() -> [Int: [URL]]? {
		do {
			guard let path = offlinePath(parentFolder: nil, name: mainPath, pathExtension: nil) else {
				displayError(title: "Offline: Error loading Track IDs on Disk", content: "Error while building path to: \(mainPath)")
				return nil
			}
			let directoryContents = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: [])
			var files: [Int: [URL]] = [:]
			for url in directoryContents {
				if let idString = url.lastPathComponent.split(separator: ".").first, let id = Int(idString) {
					files[id, default: []].append(url)
				}
			}
			return files
		} catch {
			displayError(title: "Offline: Couldn't load Track IDs from Disk", content: error.localizedDescription)
			return nil
		}
	}

	private func loadOfflineTrackIds() -> [Int]? {
		localFilesByTrackId().map { Array($0.keys) }
	}

	private var offlineTrackIdsCache: [Int]?
	private var offlineTrackIdsCacheIntact = false
	private func invalidateOfflineTrackIdsCache() {
		offlineTrackIdsCacheIntact = false
	}

	public func offlineTrackIds() -> [Int]? {
		if !offlineTrackIdsCacheIntact {
			offlineTrackIdsCache = loadOfflineTrackIds()
			offlineTrackIdsCacheIntact = true
		}
		let ids = offlineTrackIdsCache
		return ids
	}

	public func isTrackOffline(track: Track) -> Bool {
		offlineTrackIds()?.contains(track.id) ?? false
	}

	// MARK: - Sync

	private var syncRunning = false
	private var syncAgain = false

	private func sync() async {
		// Preparations (e.g. setting syncRunning) happen in asyncSync func beforehand

		print("Offline: --- Starting Sync ---")

		downloadStatus.startTask()
		defer { downloadStatus.finishTask() }

		// Load Local Track IDs
		let dbTracks = Array(db.tracks)
		guard let localFiles = localFilesByTrackId() else {
			displayError(title: "Offline: Sync Error", content: "Couldn't load Tracks from Disk")
			syncAgain = false
			syncRunning = false
			return
		}
		let localTracksIds = Array(localFiles.keys)
		print("Offline: DB IDs: \(dbTracks.map { $0.id })")
		print("Offline: Track IDs: \(localTracksIds)")

		// Diff
		var toRemove: [Int] = []
		for trackId in localTracksIds {
			if !dbTracks.contains(where: { $0.id == trackId }) {
				toRemove.append(trackId)
			}
		}

		var toAdd: [Track] = []
		var leftoverFiles: [URL] = []
		for track in dbTracks {
			if let files = localFiles[track.id] {
				// Replace the file once the offline quality or Dolby Atmos preference changed
				let wantedVariant = wantedVariant(of: track)
				if let wantedFile = files.first(where: { variant(of: $0, track: track) == wantedVariant }) {
					// Other variants remain when removing them after a download failed
					leftoverFiles += files.filter { $0 != wantedFile }
				} else {
					toAdd.append(track)
				}
			} else {
				toAdd.append(track)
			}
		}

		// Do
		if !toRemove.isEmpty {
			for trackId in toRemove {
				print("Offline: Removing \(trackId)")
				do {
					guard let files = localFiles[trackId], !files.isEmpty else {
						displayError(title: "Offline: Error while removing offline track", content: "File to remove doesn't exist: \(mainPath)/\(trackId)")
						continue
					}
					for file in files {
						try FileManager.default.removeItem(at: file)
					}
					print("Offline: Removed \(trackId)")
				} catch {
					displayError(title: "Offline: Error while removing offline track", content: "Error: \(error)")
				}
			}
			invalidateOfflineTrackIdsCache()
			uiRefreshFunc()
		}

		for file in leftoverFiles {
			print("Offline: Removing leftover file \(file.lastPathComponent)")
			do {
				try FileManager.default.removeItem(at: file)
			} catch {
				displayError(title: "Offline: Error while removing old offline file", content: "Error: \(error)")
			}
		}

		for track in toAdd {
			print("Offline: Downloading \(track.title)")
			let existingFiles = localFiles[track.id] ?? []
			guard let stream = await track.audioStream(session: session, audioQuality: session.config.offlineAudioQuality, preferDolbyAtmos: preferDolbyAtmos) else {
				if !existingFiles.isEmpty {
					print("Offline: Keeping existing file of \(track.title), as no Audio URL is available")
					continue
				}
				displayError(title: "Offline: Error while loading offline track", content: "Couldn't get Audio URL for \(track.title)")
				continue
			}
			// The Atmos stream can be unavailable, in which case the existing file can be what we'd download again
			let streamVariant = variant(of: stream)
			if existingFiles.contains(where: { variant(of: $0, track: track) == streamVariant }) {
				print("Offline: Keeping existing file of \(track.title)")
				continue
			}
			let url = stream.url
			let pathExtension = stream.pathExtension
			let marker = stream.isDolbyAtmos ? dolbyAtmosFileMarker : session.config.offlineAudioQuality.rawValue.lowercased()
			let name = "\(track.id).\(marker)"
			guard let path = offlinePath(parentFolder: mainPath, name: name, pathExtension: pathExtension) else {
				displayError(title: "Offline: Error while loading offline track", content: "Error while building path to: \(mainPath)/\(name).\(pathExtension)")
				continue
			}
			do {
				try await Network.download(url, path: path, overwrite: true)
			} catch {
				displayError(title: "Offline: Error while loading offline track", content: "Network error: \(error)")
				continue
			}
			for file in existingFiles where file.standardizedFileURL != path.standardizedFileURL {
				do {
					try FileManager.default.removeItem(at: file)
				} catch {
					displayError(title: "Offline: Error while removing old offline file", content: "Error: \(error)")
				}
			}
			print("Offline: Finished Download of \(track.title)")
			invalidateOfflineTrackIdsCache()
			uiRefreshFunc()
		}

		// Outro
		if syncAgain {
			syncAgain = false
			print("Offline: Something changed. Restarting Sync")
			await sync()
		} else {
			syncRunning = false
			print("Offline: --- Finished Sync ---")
		}
	}

	private var syncTask: Task<Void, Never>?

	private func asyncSync() {
		if syncRunning {
			syncAgain = true // If Sync is requested while running, do another one afterwards
			return
		}
		// Set before the task starts, so a second call in the meantime can't start another sync
		syncRunning = true

		syncTask = Task { await sync() }
	}

	// MARK: - All

	public func removeAll() {
		Task {
			print("Offline: Removing all \(db.tracks.count) tracks in \(db.albums.count) albums & \(db.playlists.count) playlists")
		}

		syncTask?.cancel()
		syncFavoriteTracksTask?.cancel()
		syncPlaylistsTask?.cancel()
		playlistsToSync = []

		saveFavoritesOffline = false
		Task {
			db.clear()
			asyncSync()
		}
	}

	// MARK: - Favorite Tracks

	private var favTracksSyncRunning = false
	private var favTracksSyncAgain = false

	private func syncFavoriteTracks() async {
		// Preparations (e.g. setting favTracksSyncRunning) happen in asyncSyncFavoriteTracks func beforehand

		// Prepare
		var tracks: [Track] = []
		if saveFavoritesOffline {
			if let favTracks = await session.favorites?.tracks() {
				tracks = favTracks.map { $0.item }
			} else {
				displayError(title: "Offline: Error while synchronizing Favorite Tracks", content: "")
				favTracksSyncAgain = false
				favTracksSyncRunning = false
				return
			}
		}

		// Do
		// Turned off while loading, e.g. by removing everything
		if !saveFavoritesOffline {
			tracks = []
		}
		db.setFavoriteTracks(to: tracks)
		print("Offline: Favorite Tracks synchronized")

		// Outro
		if favTracksSyncAgain {
			favTracksSyncAgain = false
			await syncFavoriteTracks()
		} else {
			favTracksSyncRunning = false
			asyncSync()
		}
	}

	private var syncFavoriteTracksTask: Task<Void, Never>?

	private func _asyncSyncFavoriteTracks() {
		if favTracksSyncRunning {
			favTracksSyncAgain = true // If Sync is requested while running, do another one afterwards
			return
		}
		favTracksSyncRunning = true

		syncFavoriteTracksTask = Task { await syncFavoriteTracks() }
	}

	@MainActor
	public func asyncSyncFavoriteTracks() {
		Task { _asyncSyncFavoriteTracks() }
	}

	// MARK: - Album

	public func isAlbumOffline(album: Album) async -> Bool {
		db.albums.contains(album)
	}

	public func getTracks(for album: Album) async -> [Track]? {
		db.albumTracks[album]
	}

	// Probably no need to do async, as it's only a single quick call to the Tidal API
	public func add(album: Album) async {
		if db.albums.contains(album) {
			print("Offline: Album \(album.title) is offline already. This suggests a bug.")
			return
		}
		// Albums from pages and search results arrive without `artists`/`streamReady`.
		// Store the full record so the Collection card and context menu work.
		var albumToStore = album
		if album.streamReady == nil || album.artists == nil {
			if let complete = await session.album(albumId: album.id) {
				albumToStore = complete
			}
		}
		guard let tracks = await session.albumTracks(albumId: album.id) else {
			return
		}
		db.add(albumToStore)
		db.setTracks(for: albumToStore, to: tracks)
		asyncSync()
	}

	public func remove(album: Album) async {
		db.remove(album)
		db.setTracks(for: album, to: nil)
		asyncSync()
	}

	// MARK: - Playlist

	private var playlistsToSync: [Playlist] = []
	private var playlistSyncRunning = false

	public func isPlaylistOffline(playlist: Playlist) async -> Bool {
		db.playlists.contains(playlist)
	}

	public func getTracks(for playlist: Playlist) async -> [Track]? {
		db.playlistTracks[playlist]
	}

	private func syncPlaylists() async {
		// Preparations (e.g. setting playlistSyncRunning) happen in syncPlaylist func beforehand

		print("Offline: --- Sync Playlist ---")

		// Prepare
		if playlistsToSync.isEmpty {
			print("Offline: No more Playlists to sync.")
			print("Offline: --- Sync Playlists finished ---")
			playlistSyncRunning = false
			return
		}
		let playlist = playlistsToSync[0]
		playlistsToSync.remove(at: 0)

		print("Offline: Sync Playlist: \(playlist.title)")

		if db.playlists.contains(playlist) {
			if let tracks = await session.playlistTracks(playlistId: playlist.id) {
				print("Offline: Playlist tracks: \(tracks.map { $0.id })")
				// Removed while loading, e.g. by removing everything
				if db.playlists.contains(playlist) {
					db.setTracks(for: playlist, to: tracks)
				}
			} else {
				// Keep the stored tracks and carry on with the other playlists
				displayError(title: "Offline: Error while synchronizing Playlist Tracks", content: "Couldn't load playlist tracks from Tidal API.")
			}
		} else {
			print("Offline: Playlist isn't marked to be offline, so deleting offline tracks, if there are any")
			db.setTracks(for: playlist, to: nil)
		}

		// Outro
		if !playlistsToSync.isEmpty {
			print("Offline: Another Playlist to Sync")
			await syncPlaylists()
		} else {
			playlistSyncRunning = false
			print("Offline: --- Sync Playlists finished ---")
			asyncSync()
		}
	}

	private var syncPlaylistsTask: Task<Void, Never>?

	public func syncPlaylist(_ playlist: Playlist) {
		if !playlistsToSync.contains(playlist) {
			playlistsToSync.append(playlist)
		}
		if !playlistSyncRunning {
			playlistSyncRunning = true
			syncPlaylistsTask = Task { await syncPlaylists() }
		}
	}

	public func add(playlist: Playlist) async {
		db.add(playlist)
		syncPlaylist(playlist)
	}

	public func remove(playlist: Playlist) async {
		db.remove(playlist)
		db.setTracks(for: playlist, to: nil)
		asyncSync()
	}

	// Useful at startup to check for changes in all Offline Playlists
	public func syncAllOfflinePlaylistsAndFavoriteTracks() async {
		for playlist in db.playlists {
			syncPlaylist(playlist)
		}
		_asyncSyncFavoriteTracks()
	}
}
