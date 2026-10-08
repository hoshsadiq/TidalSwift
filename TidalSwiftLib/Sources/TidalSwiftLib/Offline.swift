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
	private let defaults: UserDefaults

	/// Derived rather than stored, so a track is kept exactly as long as a favourite, album
	/// or playlist holds it.
	private(set) var tracks: Set<Track> = []

	/// Gives every wanted track a date and drops the dates of those that left; the whole set
	/// is checked, not only new ids, so a lost date can come back.
	@discardableResult
	private func updateTracks() -> Bool {
		let albumTracks = albums.flatMap { self.albumTracks[$0] ?? [] }
		let playlistTracks = playlists.flatMap { self.playlistTracks[$0] ?? [] }
		let newTracks = Set((favoriteTracks + standaloneOfflineTracks + albumTracks + playlistTracks).filter(\.isPlayable))
		let newIds = Set(newTracks.map(\.id))

		var datesChanged = false
		// The dates are only touched once the persisted state is loaded, so a half-loaded db
		// can't wipe a date for a track it has not read yet.
		if isLoaded {
			let onDisk = downloadDatesForTracksOnDisk?() ?? [:]
			for id in newIds where trackAddedDates[id] == nil {
				// A file on disk knows when the track was really downloaded.
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

	/// Set by `Offline` right after the db is created; a lost date is rebuilt from disk.
	var downloadDatesForTracksOnDisk: (() -> [Int: Date])? {
		didSet {
			if updateTracks() { save() }
		}
	}

	// [TrackId: DateAddedToOffline], persisted by `save()` alongside `tracks`.
	private(set) var trackAddedDates: [Int: Date] = [:]

	/// A date that already exists is never moved; a re-add must not reorder the library.
	func recordAddedDate(for trackId: Int, at date: Date = Date()) {
		guard trackAddedDates[trackId] == nil else { return }
		trackAddedDates[trackId] = date
	}

	private(set) var favoriteTracks: [Track] = [] {
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

	/// Pinned individually from the track context menu, stored as full records for the sync.
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

	init(defaults: UserDefaults = .standard) {
		self.defaults = defaults

		defaults.removeObject(forKey: "OfflineDB:Tracks")

		// A payload that is present but cannot be decoded is not a missing one: its section reads
		// as empty while its tracks are still on disk, so it is no sign its files are unwanted.
		var storedPayloadPresent = false
		var storedPayloadUnreadable = false
		func stored<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
			guard let data = defaults.data(forKey: key) else { return nil }
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

	/// Set on read or write, so an empty wanted set after a save is genuinely empty.
	private(set) var hasStoredState = false

	/// A section that could not be decoded reads as empty while its tracks are on disk.
	private(set) var storedPayloadUnreadable = false

	private func save() {
		// Once anything is written, an empty database means the wanted set really is empty.
		hasStoredState = true
		let trackAddedDatesData = try? JSONEncoder().encode(trackAddedDates)
		defaults.set(trackAddedDatesData, forKey: "OfflineDB:TrackAddedDates")

		let favoriteTracksData = try? JSONEncoder().encode(favoriteTracks)
		defaults.set(favoriteTracksData, forKey: "OfflineDB:FavoriteTracks")

		let albumsData = try? JSONEncoder().encode(albums)
		defaults.set(albumsData, forKey: "OfflineDB:Albums")

		let albumTracksData = try? JSONEncoder().encode(albumTracks)
		defaults.set(albumTracksData, forKey: "OfflineDB:AlbumTracks")

		let playlistsData = try? JSONEncoder().encode(playlists)
		defaults.set(playlistsData, forKey: "OfflineDB:Playlists")

		let playlistTracksData = try? JSONEncoder().encode(playlistTracks)
		defaults.set(playlistTracksData, forKey: "OfflineDB:PlaylistTracks")

		let standaloneOfflineTracksData = try? JSONEncoder().encode(standaloneOfflineTracks)
		defaults.set(standaloneOfflineTracksData, forKey: "OfflineDB:StandaloneOfflineTracks")
	}
}

// MARK: - Offline

public final class Offline {
	private unowned let session: Session
	private let downloadStatus: DownloadStatus
	private let mainPath = "TidalSwift Offline Library"
	@MainActor
	public var uiRefreshFunc: () -> Void = {}

	/// Read when the database is first touched, so redirecting it right after the session is
	/// built takes effect.
	var defaults: UserDefaults = .standard

	public var saveFavoritesOffline: Bool {
		get { defaults.bool(forKey: "SaveFavoritesOffline") }
		set { defaults.set(newValue, forKey: "SaveFavoritesOffline") }
	}

	public private(set) var preferDolbyAtmos: Bool {
		get { defaults.bool(forKey: "offlinePreferDolbyAtmos") }
		set { defaults.set(newValue, forKey: "offlinePreferDolbyAtmos") }
	}

	/// Middle path components: "<track ID>.atmos.m4a", "<track ID>.hires.flac",
	/// "<track ID>.<audio quality>.m4a".
	private let dolbyAtmosFileMarker = "atmos"
	/// The hi-res stereo files written before the HLS rewrite; a library that predates it
	/// still holds them, so the marker must be recognised or they are misread as lossless.
	private let hiresFileMarker = "hires"

	/// What a file on disk holds; nil quality for m4a files stored before it was in the name.
	private enum FileVariant: Equatable, Hashable {
		case dolbyAtmos
		case stereo(AudioQuality?)
	}

	/// Built on first use, so the launch task and a redirect of `defaults` both land first.
	private lazy var db = OfflineDB(defaults: defaults)
	private var hasStarted = false
	/// The disk lookup's first answer; cleared when the files change, so a later lookup re-reads.
	private var launchDiskDates: [Int: Date]?
	private var hydrationAttemptedAlbumIds: Set<Int> = []
	private let offlineLibraryRoot: URL?

	/// Test seam: the app leaves it nil and uses the track's own stream.
	var resolveOfflineStream: ((Track) async -> AudioStream?)?

	/// Test seam for the HLS branch: resolves one rung's playlist, so the sync's own ladder
	/// runs for real and a test can refuse the configured tier to see the step down.
	var resolveOfflineHLSPlaylist: ((Track, HLSRung) async throws -> URL)?

	/// Test seam: seeds the wanted set through the favourite source the app derives it from.
	func setOfflineTracksForTesting(_ tracks: [Track]) {
		db.setFavoriteTracks(to: tracks)
		startSync()
	}

	public init(session: Session, downloadStatus: DownloadStatus, offlineLibraryRoot: URL? = nil) {
		self.session = session
		self.downloadStatus = downloadStatus
		self.offlineLibraryRoot = offlineLibraryRoot

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

		// Deferred out of `init`: the listing and stat must not run on the main actor before the
		// first frame.
		Task { await self.start() }
	}

	/// One-time launch work, run in a task so the first frame does not pay for the database build.
	private func start() async {
		guard !hasStarted else { return }
		hasStarted = true
		guard let directory = offlinePath(parentFolder: nil, name: mainPath, pathExtension: nil) else {
			startSync()
			return
		}
		// Resolved off the main actor; the listing exists to rebuild a date the database lost.
		launchDiskDates = await Self.downloadDates(in: directory)
		db.downloadDatesForTracksOnDisk = { [weak self] in
			guard let self else { return [:] }
			if let snapshot = self.launchDiskDates {
				return snapshot
			}
			// The files changed since launch, so re-read them.
			return self.downloadDatesByTrackId()
		}
		// A sync the caller already asked for covers the launch; a second would double the work.
		if syncTask == nil {
			startSync()
		}
	}

	/// `nil` root (the app) is the user's Music folder; tests pass a temporary directory.
	private func offlineBaseURL() throws -> URL {
		if let offlineLibraryRoot {
			return offlineLibraryRoot
		}
		return try FileManager.default.url(for: .musicDirectory,
										   in: .userDomainMask,
										   appropriateFor: nil,
										   create: false)
	}

	/// With `offlineLibraryRoot`, the root replaces the Music folder.
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

	/// Replaces offline files in other qualities on the next sync
	public func setAudioQuality(to audioQuality: AudioQuality) {
		guard audioQuality != session.config.offlineAudioQuality else { return }
		session.config.offlineAudioQuality = audioQuality
		session.saveConfig()
		startSync()
	}

	/// Replaces the offline files of tracks with Dolby Atmos on the next sync
	public func setPreferDolbyAtmos(to preferDolbyAtmos: Bool) {
		guard preferDolbyAtmos != self.preferDolbyAtmos else { return }
		self.preferDolbyAtmos = preferDolbyAtmos
		startSync()
	}

	/// Same choice as streaming: the Atmos preference or a track with no stereo picks Atmos,
	/// otherwise the file holds the configured quality.
	private func wantedVariant(of track: Track) -> FileVariant {
		if track.hasDolbyAtmos && (preferDolbyAtmos || !track.hasStereo) {
			return .dolbyAtmos
		}
		return .stereo(session.config.offlineAudioQuality)
	}

	/// Every variant on disk that satisfies the wish for this track.
	///
	/// The configured tier is a ceiling, not "any tier at or below it": the exact wanted
	/// variant is the wish, so a Low file never satisfies a Max wish. Tidal still decides the
	/// rendition, so an Atmos-capable stereo track with the preference off may have been served
	/// the Atmos rung when every stereo rung was refused (see `HLSStreaming.rungs`), and that
	/// file must count too.
	private func acceptableVariants(of track: Track) -> Set<FileVariant> {
		var variants: Set<FileVariant> = [wantedVariant(of: track)]
		if track.hasDolbyAtmos && track.hasStereo && !preferDolbyAtmos {
			variants.insert(.dolbyAtmos)
		}
		return variants
	}

	private func variant(of url: URL, track: Track) -> FileVariant {
		let marker = url.deletingPathExtension().pathExtension
		// Legacy Atmos-only tracks were stored without a marker; every marked name is read
		// from its marker alone, because the HLS route now serves stereo for such a track.
		if marker == dolbyAtmosFileMarker || (marker.isEmpty && track.hasDolbyAtmos && !track.hasStereo) {
			return .dolbyAtmos
		}
		// The pre-rewrite hi-res stereo file: a Max FLAC the current tier naming cannot say
		if marker == hiresFileMarker {
			return .stereo(.max)
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

	/// What it lands on disk is the assembled HLS file for the tier that was served, or the
	/// direct stream for a track the HLS route cannot serve.
	private func downloadOfflineTrack(_ track: Track, existingFiles: [URL]) async -> Bool {
		guard let source = await downloadSource(for: track) else {
			reportMissingDownloadSource(for: track, existingFiles: existingFiles)
			return false
		}
		// The Atmos stream can be unavailable, in which case the existing file can be what we'd download again
		let streamVariant = variant(of: source)
		if existingFiles.contains(where: { variant(of: $0, track: track) == streamVariant }) {
			print("Offline: Keeping existing file of \(track.title)")
			return false
		}
		print("Offline: Downloading \(track.title)")
		let pathExtension = pathExtension(of: source)
		let name = "\(track.id).\(fileMarker(of: source))"
		guard let path = offlinePath(parentFolder: mainPath, name: name, pathExtension: pathExtension) else {
			displayError(title: "Offline: Error while loading offline track", content: "Error while building path to: \(mainPath)/\(name).\(pathExtension)")
			return false
		}
		do {
			try await write(source, to: path)
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

	/// HLS serves the tier ladder, so the file takes the tier that was served; the direct
	/// stream is the fallback for a track it cannot serve, so an Atmos or otherwise-refused
	/// rendition still lands.
	private func downloadSource(for track: Track) async -> OfflineDownloadSource? {
		if PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: session.hasDesktopPlaybackAccess),
		   let manifest = await resolveHLSPlaylist(for: track) {
			return .hls(manifest)
		}
		if let resolveOfflineStream {
			return await resolveOfflineStream(track).map(OfflineDownloadSource.stream)
		}
		return await track.audioStream(session: session, audioQuality: session.config.offlineAudioQuality, preferDolbyAtmos: preferDolbyAtmos).map(OfflineDownloadSource.stream)
	}

	/// A cancelled sync gives up quietly, so "remove all offline content" does not toast.
	private func reportMissingDownloadSource(for track: Track, existingFiles: [URL]) {
		if Task.isCancelled { return }
		// A stereo file at or below the ceiling is the best available tier already settled on;
		// a resolve that fails (usually offline) keeps it quietly rather than crying failure.
		if existingFiles.contains(where: { isSettledStereoFile($0, for: track) }) { return }
		if !existingFiles.isEmpty {
			// The old file stays, so a refused quality never shrinks the library
			displayError(title: "Offline: Error while loading offline track", content: "Couldn't get Audio URL for \(track.title). Keeping the existing file.")
		} else {
			displayError(title: "Offline: Error while loading offline track", content: "Couldn't get Audio URL for \(track.title)")
		}
	}

	/// A stereo file whose tier is on the current ceiling's ladder. The sync only reaches here
	/// when the exact wanted tier is not on disk, so this is a stepped-down best-available file.
	private func isSettledStereoFile(_ url: URL, for track: Track) -> Bool {
		guard case .stereo(let quality) = variant(of: url, track: track), let quality else { return false }
		return HLSStreaming.qualityLadder(for: session.config.offlineAudioQuality).contains(quality)
	}

	private func write(_ source: OfflineDownloadSource, to path: URL) async throws {
		switch source {
		case .hls(let manifest):
			try await HLSStreaming.download(manifest.playlistURL, to: path, fetch: HLSStreaming.defaultFetch(userAgent: AuthInformation.tidalClientUserAgent))
		case .stream(let stream):
			try await Network.download(stream.url, path: path, overwrite: true)
		}
	}

	private enum OfflineDownloadSource {
		case hls(HLSManifest)
		case stream(AudioStream)
	}

	private func variant(of source: OfflineDownloadSource) -> FileVariant {
		switch source {
		case .hls(let manifest):
			variant(of: manifest.rung)
		case .stream(let stream):
			variant(of: stream)
		}
	}

	/// The disk variant a served HLS rung lands as.
	private func variant(of rung: HLSRung) -> FileVariant {
		switch rung {
		case .stereo(let quality):
			.stereo(quality)
		case .dolbyAtmos:
			.dolbyAtmos
		}
	}

	private func pathExtension(of source: OfflineDownloadSource) -> String {
		switch source {
		case .hls:
			"m4a"
		case .stream(let stream):
			stream.pathExtension
		}
	}

	/// The name carries the rung the source actually holds. For HLS that is the rung Tidal
	/// served (the ladder may have stepped down from the ceiling, or to the Atmos rung), so
	/// the file and the variant check read the same thing and the sync can tell what is on
	/// disk.
	private func fileMarker(of source: OfflineDownloadSource) -> String {
		switch source {
		case .hls(let manifest):
			switch manifest.rung {
			case .stereo(let quality):
				return quality.rawValue.lowercased()
			case .dolbyAtmos:
				return dolbyAtmosFileMarker
			}
		case .stream(let stream):
			return stream.isDolbyAtmos ? dolbyAtmosFileMarker : session.config.offlineAudioQuality.rawValue.lowercased()
		}
	}

	/// A test substitutes `resolveOfflineHLSPlaylist`, so the sync needs no account. The
	/// configured offline quality is a ceiling: the ladder steps down when it is refused, so
	/// a track added offline at Max downloads its best available tier rather than failing. The
	/// served rung comes back with the playlist, so the file is named for what it holds.
	private func resolveHLSPlaylist(for track: Track) async -> HLSManifest? {
		let resolve: (Int, HLSRung) async throws -> URL
		if let resolveOfflineHLSPlaylist {
			resolve = { _, rung in try await resolveOfflineHLSPlaylist(track, rung) }
		} else {
			resolve = { trackId, rung in try await self.session.hlsManifestRequest(trackId: trackId, rung: rung) }
		}
		return try? await HLSStreaming.resolveManifest(
			trackId: track.id,
			rungs: HLSStreaming.rungs(
				for: session.config.offlineAudioQuality,
				preferDolbyAtmos: preferDolbyAtmos,
				trackHasDolbyAtmos: track.hasDolbyAtmos
			),
			resolve: resolve
		)
	}

	// These always show the goal state (planned), after all downloads have finished
	public func numberOfOfflineTracks() async -> Int {
		db.tracks.count
	}
	public func allOfflineTracks() async -> [Track] {
		Array(db.tracks)
	}

	/// Downloads from before dates were recorded have none.
	public func addedDate(forTrackId trackId: Int) -> Date? {
		db.trackAddedDates[trackId]
	}

	public func numberOfOfflineAlbums() async -> Int {
		db.albums.count
	}
	public func allOfflineAlbums() async -> [Album] {
		db.albums
	}

	/// Returns the stored albums, refetching any saved without full metadata.
	///
	/// Albums from a page or search response carry only `{id, title, cover, releaseDate}`,
	/// which leaves the Collection card without an artist and the context menu without its
	/// streaming actions. A failed fetch keeps the stored entry; attempted ids are skipped
	/// unless `retryFailed`.
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

	public func add(track: Track) async {
		db.addStandaloneOfflineTrack(track)
		startSync()
	}

	/// The track stays offline if a favourite, album or playlist still contains it.
	public func remove(track: Track) async {
		db.removeStandaloneOfflineTrack(track)
		deleteFilesNoLongerWanted([track.id])
		startSync()
	}


	/// Files on disk by track ID, any extension, so files stay usable after the quality changes
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

	/// A file's creation date is when the download wrote it and survives relaunches.
	private func downloadDatesByTrackId() -> [Int: Date] {
		guard let files = localFilesByTrackId() else { return [:] }
		var dates: [Int: Date] = [:]
		for (id, urls) in files {
			let creationDates = urls.compactMap { url in
				try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
			}
			if let earliest = creationDates.min() {
				dates[id] = earliest
			}
		}
		return dates
	}

	/// The same lookup off the main actor, for the launch path.
	@concurrent
	private nonisolated static func downloadDates(in directory: URL) async -> [Int: Date] {
		let urls = (try? FileManager.default.contentsOfDirectory(
			at: directory, includingPropertiesForKeys: [.creationDateKey], options: []
		)) ?? []
		var dates: [Int: Date] = [:]
		for url in urls {
			guard let idString = url.lastPathComponent.split(separator: ".").first,
				  let id = Int(idString),
				  let creation = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { continue }
			dates[id] = min(dates[id] ?? creation, creation)
		}
		return dates
	}

	private var offlineTrackIdsCache: [Int]?
	private var offlineTrackIdsCacheIntact = false
	private func invalidateOfflineTrackIdsCache() {
		offlineTrackIdsCacheIntact = false
		// The files changed, so the launch snapshot of their dates is stale.
		launchDiskDates = nil
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

		print("Offline: --- Starting Sync ---")

		downloadStatus.startTask()
		defer { downloadStatus.finishTask() }

		guard let localFiles = localFilesByTrackId() else {
			displayError(title: "Offline: Sync Error", content: "Couldn't load Tracks from Disk")
			syncAgain = false
			syncRunning = false
			return
		}
		let dbTracks = Array(db.tracks)
		print("Offline: DB IDs: \(dbTracks.map { $0.id })")
		print("Offline: Track IDs: \(Array(localFiles.keys))")

		removeOrphanedTemporaryFiles()
		let plan = syncPlan(dbTracks: dbTracks, localFiles: localFiles)

		// Download first, so nothing is deleted before its replacement is on disk.
		for track in plan.toAdd {
			// `removeAll()` cancels this sync; the rest of the pass would resolve every
			// remaining track only to report a failed download.
			if Task.isCancelled { break }
			_ = await downloadOfflineTrack(track, existingFiles: localFiles[track.id] ?? [])
		}

		removeLeftoverFiles(plan.leftoverFiles)
		removeDepartedTracks(keptTrackIdsWhenDatabaseUnreadable(plan.toRemove), localFiles: localFiles)

		if syncAgain {
			syncAgain = false
			print("Offline: Something changed. Restarting Sync")
			await sync()
		} else {
			syncRunning = false
			print("Offline: --- Finished Sync ---")
		}
	}

	/// One pass: what to remove, what to download, and the files a re-download made stale.
	private struct SyncPlan {
		var toRemove: [Int] = []
		var toAdd: [Track] = []
		var leftoverFiles: [URL] = []
	}

	/// A wanted track keeps at most one file, matching an acceptable variant; the rest is a
	/// replacement or a stale file to prune.
	private func syncPlan(dbTracks: [Track], localFiles: [Int: [URL]]) -> SyncPlan {
		var plan = SyncPlan()
		for trackId in localFiles.keys where !dbTracks.contains(where: { $0.id == trackId }) {
			plan.toRemove.append(trackId)
		}
		for track in dbTracks {
			guard let files = localFiles[track.id] else {
				plan.toAdd.append(track)
				continue
			}
			// Any acceptable variant already satisfies the wish; the rest are leftovers once a
			// replacement is on disk.
			let acceptable = acceptableVariants(of: track)
			if let matchingFile = files.first(where: { acceptable.contains(variant(of: $0, track: track)) }) {
				plan.leftoverFiles += files.filter { $0 != matchingFile }
			} else {
				plan.toAdd.append(track)
			}
		}
		return plan
	}

	/// Removes the hidden temporary siblings `HLSStreaming.assemble` writes while it
	/// downloads a track. Its `defer` removes one on the normal error paths, but a hard
	/// crash mid-download skips it: `localFilesByTrackId` cannot parse the leading dot and
	/// `removeAll` iterates only indexed files, so without this the file sits in the
	/// library forever.
	private func removeOrphanedTemporaryFiles() {
		guard let path = offlinePath(parentFolder: nil, name: mainPath, pathExtension: nil),
			  let contents = try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: []) else {
			return
		}
		for url in contents where HLSStreaming.isTemporarySibling(url) {
			try? FileManager.default.removeItem(at: url)
		}
	}

	/// Prunes the variants a successful re-download made stale, so one file per track remains.
	private func removeLeftoverFiles(_ files: [URL]) {
		for file in files {
			if Task.isCancelled { break }
			print("Offline: Removing leftover file \(file.lastPathComponent)")
			do {
				try FileManager.default.removeItem(at: file)
			} catch {
				displayError(title: "Offline: Error while removing old offline file", content: "Error: \(error)")
			}
		}
	}

	/// A wanted set that could not be read in full next to files on disk is not
	/// "nothing is wanted any more": it is a database that never loaded or was lost.
	/// `removeAll()` clears the database and deletes its files itself, so a deliberate
	/// removal never depends on this inference. A lost logout wipe cost a 22-file library.
	private func keptTrackIdsWhenDatabaseUnreadable(_ toRemove: [Int]) -> [Int] {
		let databaseUnreadable = !db.hasStoredState || db.storedPayloadUnreadable
		guard databaseUnreadable, !toRemove.isEmpty else { return toRemove }
		displayError(
			title: "Offline: Nothing marked for offline",
			content: "Your offline list is empty or unreadable, so \(toRemove.count) downloaded \(toRemove.count == 1 ? "track was" : "tracks were") kept."
		)
		return []
	}

	/// Tracks that genuinely left the offline set are removed in the same sync.
	private func removeDepartedTracks(_ trackIds: [Int], localFiles: [Int: [URL]]) {
		guard !trackIds.isEmpty else { return }
		for trackId in trackIds {
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

	private var syncTask: Task<Void, Never>?

	private func startSync() {
		if syncRunning {
			syncAgain = true // If Sync is requested while running, do another one afterwards
			return
		}
		// Set before the task starts, so a second call in the meantime can't start another sync
		syncRunning = true

		syncTask = Task { await sync() }
	}

	/// Test seam: waits for the sync `init` starts, so a test can assert on the files instead
	/// of racing it.
	@discardableResult
	func awaitOngoingSync(timeout: TimeInterval = 5) async -> Bool {
		// `syncTask` is only set once the launch task reaches `startSync`.
		let deadline = Date().addingTimeInterval(timeout)
		while syncTask == nil {
			if Date() >= deadline { return false }
			await Task.yield()
		}
		await syncTask?.value
		return true
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
			// An empty database no longer means "delete what is on disk".
			for (_, trackFiles) in files {
				for file in trackFiles {
					try? FileManager.default.removeItem(at: file)
				}
			}
			invalidateOfflineTrackIdsCache()
			startSync()
		}
	}

	/// A track another source still wants keeps its file, or the next sync would download it again.
	private func deleteFilesNoLongerWanted(_ trackIds: [Int]) {
		let wanted = db.tracks
		deleteFiles(for: trackIds.filter { id in !wanted.contains { $0.id == id } })
	}

	/// The deliberate removal paths use this, not the sync's database-diff inference.
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

		// A cancelled sync leaves the stored set alone: `removeAll()` owns the removal.
		if Task.isCancelled {
			favTracksSyncAgain = false
			favTracksSyncRunning = false
			return
		}

		guard let loaded = await favoritesForSync() else {
			favTracksSyncAgain = false
			favTracksSyncRunning = false
			// A cancelled request is not a failure: the sync was asked to stop.
			if !Task.isCancelled {
				displayError(title: "Offline: Error while synchronizing Favorite Tracks", content: "")
			}
			return
		}

		var tracks = loaded
		// Turned off while loading, e.g. by removing everything.
		if !saveFavoritesOffline {
			deleteFilesNoLongerWanted(db.favoriteTracks.map(\.id))
			tracks = []
		}
		db.setFavoriteTracks(to: tracks)
		print("Offline: Favorite Tracks synchronized")

		if favTracksSyncAgain {
			favTracksSyncAgain = false
			await syncFavoriteTracks()
		} else {
			favTracksSyncRunning = false
			startSync()
		}
	}

	/// nil means the request failed; an empty array is a genuinely empty set.
	private func favoritesForSync() async -> [Track]? {
		guard saveFavoritesOffline else { return [] }
		guard let favTracks = await session.favorites?.tracks() else { return nil }
		return favTracks.map { $0.item }
	}

	private var syncFavoriteTracksTask: Task<Void, Never>?

	private func startFavoriteTracksSync() {
		if favTracksSyncRunning {
			favTracksSyncAgain = true // If Sync is requested while running, do another one afterwards
			return
		}
		favTracksSyncRunning = true

		syncFavoriteTracksTask = Task { await syncFavoriteTracks() }
	}

	@MainActor
	public func asyncSyncFavoriteTracks() {
		Task { startFavoriteTracksSync() }
	}

	// MARK: - Album

	public func isAlbumOffline(album: Album) async -> Bool {
		db.albums.contains(album)
	}

	public func getTracks(for album: Album) async -> [Track]? {
		db.albumTracks[album]
	}

	public func add(album: Album) async {
		if db.albums.contains(album) {
			print("Offline: Album \(album.title) is offline already. This suggests a bug.")
			return
		}
		// Albums from pages and search results arrive without `artists`/`streamReady`.
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
		startSync()
	}

	public func remove(album: Album) async {
		// The ids are read before the database forgets them: the sync no longer treats "not in
		// the database" as "delete".
		let trackIds = (db.albumTracks[album] ?? []).map(\.id)
		db.remove(album)
		db.setTracks(for: album, to: nil)
		deleteFilesNoLongerWanted(trackIds)
		startSync()
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

		print("Offline: --- Sync Playlist ---")

		// A cancelled sync stops rather than fetching every queued playlist.
		if Task.isCancelled {
			playlistSyncRunning = false
			print("Offline: --- Sync Playlists cancelled ---")
			return
		}

		if playlistsToSync.isEmpty {
			print("Offline: No more Playlists to sync.")
			print("Offline: --- Sync Playlists finished ---")
			playlistSyncRunning = false
			return
		}
		let playlist = playlistsToSync[0]
		playlistsToSync.remove(at: 0)

		print("Offline: Sync Playlist: \(playlist.title)")
		await syncPlaylistTracks(playlist)

		if !playlistsToSync.isEmpty {
			print("Offline: Another Playlist to Sync")
			await syncPlaylists()
		} else {
			playlistSyncRunning = false
			print("Offline: --- Sync Playlists finished ---")
			startSync()
		}
	}

	/// A playlist removed while loading has its tracks cleared; a failed request keeps them.
	private func syncPlaylistTracks(_ playlist: Playlist) async {
		guard db.playlists.contains(playlist) else {
			print("Offline: Playlist isn't marked to be offline, so deleting offline tracks, if there are any")
			db.setTracks(for: playlist, to: nil)
			return
		}
		guard let tracks = await session.playlistTracks(playlistId: playlist.id) else {
			// Keep the stored tracks; a cancelled request is not a failure.
			if !Task.isCancelled {
				displayError(title: "Offline: Error while synchronizing Playlist Tracks", content: "Couldn't load playlist tracks from Tidal API.")
			}
			return
		}
		print("Offline: Playlist tracks: \(tracks.map { $0.id })")
		// Removed while loading, e.g. by removing everything
		if db.playlists.contains(playlist) {
			db.setTracks(for: playlist, to: tracks)
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
		startSync()
	}

	public func syncAllOfflinePlaylistsAndFavoriteTracks() async {
		for playlist in db.playlists {
			syncPlaylist(playlist)
		}
		startFavoriteTracksSync()
	}
}
