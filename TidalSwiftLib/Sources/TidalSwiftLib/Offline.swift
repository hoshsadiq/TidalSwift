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

	/// Test seam: see `Offline.setOfflineTracksForTesting`. The app derives the set
	/// from favourites, albums and playlists instead.
	func replaceTracksForTesting(_ newTracks: Set<Track>) {
		tracks = newTracks
	}

	/// Gives every wanted track a date and drops the dates of tracks that left.
	/// The whole wanted set is checked, not only the ids that are new since the
	/// last pass, so a date that was lost can come back. Returns whether a date
	/// changed, so a no-op load can skip the write.
	@discardableResult
	private func updateTracks() -> Bool {
		let albumTracks = albums.flatMap { self.albumTracks[$0] ?? [] }
		let playlistTracks = playlists.flatMap { self.playlistTracks[$0] ?? [] }
		let newTracks = Set((favoriteTracks + standaloneOfflineTracks + albumTracks + playlistTracks).filter(\.isPlayable))
		let newIds = Set(newTracks.map(\.id))

		var datesChanged = false
		// The dates are only touched once the persisted state is loaded, so a
		// half-loaded db can't wipe a date for a track it simply hasn't read yet.
		if isLoaded {
			let onDisk = downloadDatesForTracksOnDisk?() ?? [:]
			for id in newIds where trackAddedDates[id] == nil {
				// A file on disk knows when the track was really downloaded; a
				// wanted track without one was only asked for now.
				recordAddedDate(for: id, at: onDisk[id] ?? Date())
				datesChanged = true
			}
			for id in Set(trackAddedDates.keys).subtracting(newIds) {
				trackAddedDates[id] = nil
				datesChanged = true
			}
		}
		tracks = newTracks
		return datesChanged
	}

	private var isLoaded = false

	/// Resolves the download date of every track file on disk, by track id.
	/// `Offline` sets it right after creating the db, since it owns the
	/// filesystem. Installing it also triggers a backfill, which is where a lost
	/// date is rebuilt from the files rather than stamped with "now".
	var downloadDatesForTracksOnDisk: (() -> [Int: Date])? {
		didSet {
			if updateTracks() { save() }
		}
	}

	// [TrackId: DateAddedToOffline]
	// Persisted by the adjacent `tracks` derivation's save(); always changed together with it.
	private(set) var trackAddedDates: [Int: Date] = [:]

	/// Records when a track joined the offline set. A date that already exists is
	/// never moved: the map is history, and a re-add must not reorder the library.
	func recordAddedDate(for trackId: Int, at date: Date = Date()) {
		guard trackAddedDates[trackId] == nil else { return }
		trackAddedDates[trackId] = date
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

		// A payload that is present but cannot be decoded is not a missing one: its
		// section reads as empty while its tracks are still on disk. Both facts are
		// recorded, because they decide whether the sync may treat the files of the
		// unread sections as unwanted.
		var storedPayloadPresent = false
		var storedPayloadUnreadable = false
		func stored<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
			guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
			storedPayloadPresent = true
			guard let value = try? JSONDecoder().decode(type, from: data) else {
				storedPayloadUnreadable = true
				return nil
			}
			return value
		}

		trackAddedDates = stored([Int: Date].self, forKey: "OfflineDB:TrackAddedDates") ?? [:]
		favoriteTracks = stored([Track].self, forKey: "OfflineDB:FavoriteTracks") ?? []
		albums = stored([Album].self, forKey: "OfflineDB:Albums") ?? []
		albumTracks = stored([Album: [Track]].self, forKey: "OfflineDB:AlbumTracks") ?? [:]
		playlists = stored([Playlist].self, forKey: "OfflineDB:Playlists") ?? []
		playlistTracks = stored([Playlist: [Track]].self, forKey: "OfflineDB:PlaylistTracks") ?? [:]
		standaloneOfflineTracks = stored([Track].self, forKey: "OfflineDB:StandaloneOfflineTracks") ?? []

		hasStoredState = storedPayloadPresent
		self.storedPayloadUnreadable = storedPayloadUnreadable

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

	/// Whether any offline payload was stored, readable or not. Set when the database is
	/// read or written, so an empty wanted set after a save is genuinely empty rather
	/// than lost.
	private(set) var hasStoredState = false

	/// Whether a stored payload could not be decoded. Such a section reads as empty
	/// while its tracks are still on disk, so the wanted set is unknown rather than
	/// empty and the sync keeps the files it cannot account for.
	private(set) var storedPayloadUnreadable = false

	private func save() {
		// Once anything is written, the stored state is ours: an empty database after
		// this point means the wanted set really is empty, not that it was lost.
		hasStoredState = true
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

	/// The file markers, all middle path components: Dolby Atmos files are named
	/// "<track ID>.atmos.m4a", decrypted hi-res stereo files "<track ID>.hires.flac",
	/// and stereo files "<track ID>.<audio quality>.<extension>".
	private let dolbyAtmosFileMarker = "atmos"
	private let hiResStereoFileMarker = "hires"

	/// What a file on disk holds. The quality is nil for m4a files stored before it was part of the name.
	private enum FileVariant: Equatable, Hashable {
		case dolbyAtmos
		case hiResStereo
		case stereo(AudioQuality?)
	}

	private let db = OfflineDB()
	private var hydrationAttemptedAlbumIds: Set<Int> = []
	private let offlineLibraryRoot: URL?

	/// Resolves the stream a sync downloads for a track. The app leaves it nil and
	/// uses the track's own stream; tests set it to force a download failure that
	/// would otherwise need a live Tidal account.
	var resolveOfflineStream: ((Track) async -> AudioStream?)?

	/// Test seam for the hi-res branch, the counterpart of `resolveOfflineStream`:
	/// returns an encrypted source and its wrapped key so a test can drive the
	/// download-and-decrypt path without a live Tidal account. The app leaves it nil.
	var resolveHiResOfflineStream: ((Track) async -> AcceptedHiResManifest?)?

	/// Test seam for the DASH branch, again the counterpart of `resolveOfflineStream`:
	/// returns the manifest a sync would assemble, so a test can drive the
	/// segment-fetch path against `file://` segments without a live Tidal account.
	/// The app leaves it nil and asks the session.
	var resolveOfflineDashManifest: ((Track) async -> DashAudioManifest?)?

	/// Test seam: seeds the offline track set and starts a sync, so a test can
	/// drive a pass against a known state. The app never calls this.
	func setOfflineTracksForTesting(_ tracks: [Track]) {
		db.replaceTracksForTesting(Set(tracks))
		asyncSync()
	}

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

		// Installing the disk lookup lets the db rebuild a lost "added to offline"
		// date from the files it already has, instead of stamping "now" on them.
		db.downloadDatesForTracksOnDisk = { [weak self] in
			self?.downloadDatesByTrackId() ?? [:]
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

	/// Same choice as streaming, so offline playback sounds the same. At the FLAC tiers
	/// the hi-res stereo route upgrades the stereo wish when the session can use it; the
	/// Atmos preference still wins, so its meaning is unchanged.
	private func wantedVariant(of track: Track) -> FileVariant {
		if track.hasDolbyAtmos && (preferDolbyAtmos || !track.hasStereo) {
			return .dolbyAtmos
		}
		if HiResStreaming.usesHiResStereo(for: track, session: session, quality: session.config.offlineAudioQuality, preferDolbyAtmos: preferDolbyAtmos) {
			return .hiResStereo
		}
		return .stereo(session.config.offlineAudioQuality)
	}

	/// Every variant on disk that counts as satisfying the wish for this track.
	///
	/// Tidal decides which rendition a track is served in, not us. An Atmos-capable
	/// track that also declares stereo is refused by `streamUrl` at every tier and
	/// answered by the manifest instead, which serves the Atmos rendition even with
	/// the Atmos preference off (see `Track.audioStream`). With the preference off
	/// such a track is therefore wanted in either rendition: a file matching either
	/// must be neither re-downloaded nor pruned as a leftover. This is not
	/// sloppiness — `wantedVariant` above is only the rendition the sync prefers,
	/// while this set is what it accepts.
	private func acceptableVariants(of track: Track) -> Set<FileVariant> {
		var variants: Set<FileVariant> = [wantedVariant(of: track)]
		// A dual-format track with the Atmos preference off may still be served Atmos
		// when Tidal refuses its stereo rendition, so either file satisfies the wish.
		if track.hasDolbyAtmos && track.hasStereo && !preferDolbyAtmos {
			variants.insert(.dolbyAtmos)
		}
		return variants
	}

	private func variant(of url: URL, track: Track) -> FileVariant {
		let marker = url.deletingPathExtension().pathExtension
		if marker == hiResStereoFileMarker {
			return .hiResStereo
		}
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

	/// Resolves and downloads one wanted track, returning whether a file was written.
	/// The hi-res stereo route comes first when the policy says so; what lands on disk
	/// from it is decrypted, never the encrypted stream. A tier whose `streamUrl` is
	/// refused falls back to the DASH assembly, which is a plain AAC file when it
	/// succeeds and no file at all when it fails.
	private func downloadOfflineTrack(_ track: Track, existingFiles: [URL]) async -> Bool {
		print("Offline: Downloading \(track.title)")
		let source: OfflineDownloadSource?
		if HiResStreaming.usesHiResStereo(for: track, session: session, quality: session.config.offlineAudioQuality, preferDolbyAtmos: preferDolbyAtmos),
		   let hiRes = await resolveHiResSource(for: track) {
			source = .hiRes(hiRes)
		} else if let resolveOfflineStream {
			source = await resolveOfflineStream(track).map(OfflineDownloadSource.stream)
		} else {
			source = await track.audioStream(session: session, audioQuality: session.config.offlineAudioQuality, preferDolbyAtmos: preferDolbyAtmos).map(OfflineDownloadSource.stream)
		}
		// DASH is the fallback for the tiers whose `streamUrl` is refused: only when
		// nothing else resolved, so an Atmos or hi-res rendition still wins.
		var resolvedSource = source
		if resolvedSource == nil {
			resolvedSource = await resolveDashSource(for: track).map(OfflineDownloadSource.dash)
		}
		guard let source = resolvedSource else {
			// A cancelled sync gives up quietly: reporting each remaining track as a failed
			// download would toast on a deliberate "remove all offline content".
			if Task.isCancelled { return false }
			if !existingFiles.isEmpty {
				// The old file stays, so a refused quality never shrinks the library
				displayError(title: "Offline: Error while loading offline track", content: "Couldn't get Audio URL for \(track.title). Keeping the existing file.")
			} else {
				displayError(title: "Offline: Error while loading offline track", content: "Couldn't get Audio URL for \(track.title)")
			}
			return false
		}
		// The Atmos stream can be unavailable, in which case the existing file can be what we'd download again
		let streamVariant = variant(of: source)
		if existingFiles.contains(where: { variant(of: $0, track: track) == streamVariant }) {
			print("Offline: Keeping existing file of \(track.title)")
			return false
		}
		let pathExtension = pathExtension(of: source)
		let marker = fileMarker(of: source)
		let name = "\(track.id).\(marker)"
		guard let path = offlinePath(parentFolder: mainPath, name: name, pathExtension: pathExtension) else {
			displayError(title: "Offline: Error while loading offline track", content: "Error while building path to: \(mainPath)/\(name).\(pathExtension)")
			return false
		}
		do {
			switch source {
			case .hiRes(let manifest):
				try await HiResStreaming.downloadAndDecrypt(manifest, to: path)
			case .dash(let manifest):
				try await DashAudio.assemble(manifest, to: path)
			case .stream(let stream):
				try await Network.download(stream.url, path: path, overwrite: true)
			}
		} catch {
			if Task.isCancelled { return false }
			displayError(title: "Offline: Error while loading offline track", content: "Network error: \(error)")
			return false
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
		return true
	}

	private enum OfflineDownloadSource {
		case hiRes(AcceptedHiResManifest)
		case dash(DashAudioManifest)
		case stream(AudioStream)
	}

	private func variant(of source: OfflineDownloadSource) -> FileVariant {
		switch source {
		case .hiRes:
			.hiResStereo
		case .dash:
			.stereo(session.config.offlineAudioQuality)
		case .stream(let stream):
			variant(of: stream)
		}
	}

	private func pathExtension(of source: OfflineDownloadSource) -> String {
		switch source {
		case .hiRes:
			"flac"
		case .dash:
			"m4a"
		case .stream(let stream):
			stream.pathExtension
		}
	}

	private func fileMarker(of source: OfflineDownloadSource) -> String {
		switch source {
		case .hiRes:
			hiResStereoFileMarker
		case .dash:
			session.config.offlineAudioQuality.rawValue.lowercased()
		case .stream(let stream):
			stream.isDolbyAtmos ? dolbyAtmosFileMarker : session.config.offlineAudioQuality.rawValue.lowercased()
		}
	}

	/// The hi-res source for a sync. In production the session resolves it; a test
	/// substitutes `resolveHiResOfflineStream` so the encrypted fixture needs no account.
	private func resolveHiResSource(for track: Track) async -> AcceptedHiResManifest? {
		if let resolveHiResOfflineStream {
			return await resolveHiResOfflineStream(track)
		}
		guard case .resolved(let manifest) = await session.hiResStereoStream(trackId: track.id) else {
			return nil
		}
		return manifest
	}

	/// The DASH source for a sync, only for the stereo tiers Tidal serves as DASH.
	/// The manifest is assembled into a local file; in production the session resolves
	/// it, while a test substitutes `resolveOfflineDashManifest` so the fixture needs
	/// no account. A test that substituted `resolveOfflineStream` must not hit the
	/// network here either.
	private func resolveDashSource(for track: Track) async -> DashAudioManifest? {
		guard case .stereo(let quality) = wantedVariant(of: track), let quality, quality == .medium || quality == .low else {
			return nil
		}
		if let resolveOfflineDashManifest {
			return await resolveOfflineDashManifest(track)
		}
		guard resolveOfflineStream == nil else { return nil }
		return await session.dashAudioManifest(trackId: track.id, audioQuality: quality)
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
		deleteFilesNoLongerWanted([track.id])
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

	/// The download date of every offline file, by track ID, for rebuilding an
	/// "added to offline" date that was lost. A file's creation date is when the
	/// download wrote it, so it stays the same across launches.
	private func downloadDatesByTrackId() -> [Int: Date] {
		guard let files = localFilesByTrackId() else { return [:] }
		var dates: [Int: Date] = [:]
		for (id, urls) in files {
			let creationDates = urls.compactMap { url in
				try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
			}
			// A re-download can leave a second file behind; the earliest creation
			// date is when the track first became offline.
			if let earliest = creationDates.min() {
				dates[id] = earliest
			}
		}
		return dates
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
				// Replace the file once the offline quality or Dolby Atmos preference
				// changed. Any acceptable variant counts as already satisfying the
				// wish; the rest are leftovers once a replacement is on disk.
				let acceptable = acceptableVariants(of: track)
				if let matchingFile = files.first(where: { acceptable.contains(variant(of: $0, track: track)) }) {
					leftoverFiles += files.filter { $0 != matchingFile }
				} else {
					toAdd.append(track)
				}
			} else {
				toAdd.append(track)
			}
		}

		// Download first, so nothing is deleted before its replacement is on disk.
		// A track whose download fails keeps the file it already has.
		for track in toAdd {
			// `removeAll()` cancels this sync. The rest of the pass would resolve every
			// remaining track only to report each cancellation as a failed download.
			if Task.isCancelled { break }
			await downloadOfflineTrack(track, existingFiles: localFiles[track.id] ?? [])
		}

		// Prune the variants a successful re-download made stale, so one file
		// per track remains once its replacement is safely on disk.
		for file in leftoverFiles {
			if Task.isCancelled { break }
			print("Offline: Removing leftover file \(file.lastPathComponent)")
			do {
				try FileManager.default.removeItem(at: file)
			} catch {
				displayError(title: "Offline: Error while removing old offline file", content: "Error: \(error)")
			}
		}

		// A wanted set that could not be read in full next to files on disk is not
		// "nothing is wanted any more": it is a database that never loaded or was lost.
		// `removeAll()` clears the database and deletes the files it names itself, so a
		// deliberate removal never depends on this inference. A single lost logout wipe
		// cost a 22-file library, so the guard stays.
		if (!db.hasStoredState || db.storedPayloadUnreadable) && !toRemove.isEmpty {
			displayError(
				title: "Offline: Nothing marked for offline",
				content: "Your offline list is empty or unreadable, so \(toRemove.count) downloaded \(toRemove.count == 1 ? "track was" : "tracks were") kept."
		)
			toRemove = []
		}

		// Tracks that genuinely left the offline set are removed in the same sync.
		if !toRemove.isEmpty {
			for trackId in toRemove {
				if Task.isCancelled { break }
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

	/// Test seam: waits for the sync `init` starts in a Task to finish, so a test
	/// can assert on the resulting files instead of racing the background sync.
	func awaitOngoingSync() async {
		// `syncTask` is only set once `asyncSync` runs; yield until that Task has.
		while syncTask == nil {
			await Task.yield()
		}
		await syncTask?.value
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
		let files = localFilesByTrackId() ?? [:]
		Task {
			db.clear()
			// Delete here rather than leaving it to the sync: an empty database no longer
			// means "delete what is on disk", so the removal has to be explicit.
			for (_, trackFiles) in files {
				for file in trackFiles {
					try? FileManager.default.removeItem(at: file)
				}
			}
			asyncSync()
		}
	}

	/// Deletes the stored files of tracks that have left the wanted set for good. A
	/// track another source still wants keeps its file: removing it from one album does
	/// not take it out of a playlist that also holds it. Deleting it here would be undone
	/// by the next sync downloading it again, so the removal would look like it did
	/// nothing.
	private func deleteFilesNoLongerWanted(_ trackIds: [Int]) {
		let wanted = db.tracks
		deleteFiles(for: trackIds.filter { id in !wanted.contains { $0.id == id } })
	}

	/// Deletes every stored file of the given tracks. The deliberate removal paths use
	/// this so they do not depend on the sync inferring a removal from the database
	/// diff — an empty database is not treated as "delete everything".
	private func deleteFiles(for trackIds: [Int]) {
		guard !trackIds.isEmpty, let localFiles = localFilesByTrackId() else { return }
		for trackId in trackIds {
			for file in localFiles[trackId] ?? [] {
				do {
					try FileManager.default.removeItem(at: file)
					print("Offline: Removed \(file.lastPathComponent)")
				} catch {
					displayError(title: "Offline: Error while removing offline track", content: "Error: \(error)")
				}
			}
		}
		invalidateOfflineTrackIdsCache()
		uiRefreshFunc()
	}

	// MARK: - Favorite Tracks

	private var favTracksSyncRunning = false
	private var favTracksSyncAgain = false

	private func syncFavoriteTracks() async {
		// Preparations (e.g. setting favTracksSyncRunning) happen in asyncSyncFavoriteTracks func beforehand

		// A cancelled sync stops cleanly and leaves the stored set alone: `removeAll()`
		// owns the removal and the files, so continuing would only report failures.
		if Task.isCancelled {
			favTracksSyncAgain = false
			favTracksSyncRunning = false
			return
		}

		// Prepare
		var tracks: [Track] = []
		if saveFavoritesOffline {
			if let favTracks = await session.favorites?.tracks() {
				tracks = favTracks.map { $0.item }
			} else {
				favTracksSyncAgain = false
				favTracksSyncRunning = false
				// A cancelled request is not a failure: the sync was asked to stop.
				if !Task.isCancelled {
					displayError(title: "Offline: Error while synchronizing Favorite Tracks", content: "")
				}
				return
			}
		}

		// Do
		// Turned off while loading, e.g. by removing everything. The files of the tracks
		// that leave the set are deleted here, because the sync no longer infers a
		// removal from a shrinking set.
		if !saveFavoritesOffline {
			let leaving = db.favoriteTracks.map(\.id)
			deleteFilesNoLongerWanted(leaving)
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
		// The track ids have to be read before the database forgets them: the sync no
		// longer treats "not in the database" as "delete", so the removal is explicit.
		let trackIds = (db.albumTracks[album] ?? []).map(\.id)
		db.remove(album)
		db.setTracks(for: album, to: nil)
		deleteFilesNoLongerWanted(trackIds)
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

		// A cancelled sync stops cleanly rather than fetching every playlist it still
		// has queued; `removeAll()` empties the queue itself.
		if Task.isCancelled {
			playlistSyncRunning = false
			print("Offline: --- Sync Playlists cancelled ---")
			return
		}

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
				// A cancelled request is not a failure: the sync was asked to stop.
				if !Task.isCancelled {
					displayError(title: "Offline: Error while synchronizing Playlist Tracks", content: "Couldn't load playlist tracks from Tidal API.")
				}
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
		let trackIds = (db.playlistTracks[playlist] ?? []).map(\.id)
		db.remove(playlist)
		db.setTracks(for: playlist, to: nil)
		deleteFilesNoLongerWanted(trackIds)
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
