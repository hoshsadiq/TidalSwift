//
//  Download.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation
import AVFoundation
import Observation

@Observable
public final class DownloadStatus {
	public var downloadingTasks: Int = 0

	func startTask() {
		downloadingTasks += 1
	}

	func finishTask() {
		downloadingTasks -= 1
	}
}

public struct DownloadErrors {
	var affectedTracks = Set<Track>()
	var affectedAlbums = Set<Album>()
	var affectedArtists = Set<Artist>()
	var affectedPlaylists = Set<Playlist>()
}

public enum DownloadLocation {
	case downloads
	case music
}

public class Download {
	unowned let session: Session
	unowned let metadata: Metadata
	private let downloadStatus: DownloadStatus


	private var dispatchQueue = DispatchQueue(label: "io.hosh.TidalSwift.download", qos: .background)

	init(session: Session, metadata: Metadata, downloadStatus: DownloadStatus) {
		self.session = session
		self.metadata = metadata
		self.downloadStatus = downloadStatus
	}

	func formFileName(_ track: Track) -> String {
		var title = track.title
		if let version = track.version {
			title += " (\(version))"
		}
		return "\(track.trackNumber) \(title) - \(track.artists.formArtistString())"
	}

	func formFileName(_ video: Video) -> String {
		"\(video.trackNumber) \(video.title) - \(video.artists.formArtistString())"
	}

	/// `audioQuality` is explicit because this app keeps two qualities: the one the user
	/// picked for playback, and a separate one for offline sync. A manual download
	/// follows the playback choice; sync uses `config.offlineAudioQuality`.
	public func download(track: Track, parentFolder: String = "", audioQuality: AudioQuality) async -> Bool {
		downloadStatus.startTask()
		defer { downloadStatus.finishTask() }

		let filename = formFileName(track)
		print("Downloading: \(filename)")

		// The hi-res stereo route when the session can use it, the requested quality is a
		// FLAC tier and the Atmos preference does not ask for the other rendition: the
		// encrypted rendition is downloaded and decrypted, so the file on disk is a
		// playable FLAC and never the encrypted stream. At Medium/Low the route is DASH
		// instead, which the branch below assembles.
		if HiResStreaming.usesHiResStereo(
			for: track,
			session: session,
			quality: audioQuality,
			preferDolbyAtmos: session.helpers.offline.preferDolbyAtmos
		),
		   case .resolved(let manifest) = await session.hiResStereoStream(trackId: track.id) {
			return await save(track, named: filename, parentFolder: parentFolder, pathExtension: "flac") { path in
				try await HiResStreaming.downloadAndDecrypt(manifest, to: path)
			}
		}

		// At High/Low `streamUrl` is refused and the desktop endpoint answers an
		// unencrypted AAC DASH manifest instead. A track that wants Atmos keeps it,
		// so the assembly only fills the plain stereo tiers.
		let wantsAtmos = track.hasDolbyAtmos && (session.helpers.offline.preferDolbyAtmos || !track.hasStereo)
		if audioQuality == .medium || audioQuality == .low, track.hasStereo, !wantsAtmos,
		   let manifest = await session.dashAudioManifest(trackId: track.id, audioQuality: audioQuality) {
			return await save(track, named: filename, parentFolder: parentFolder, pathExtension: "m4a") { path in
				try await DashAudio.assemble(manifest, to: path)
			}
		}

		guard let stream = await track.audioStream(session: session, audioQuality: audioQuality, preferDolbyAtmos: session.helpers.offline.preferDolbyAtmos) else {
			return false
		}
		return await save(track, named: filename, parentFolder: parentFolder, pathExtension: stream.pathExtension) { path in
			try await Network.download(stream.url, path: path, overwrite: true)
		}
	}

	/// Builds the path under the downloads folder, writes the track's audio there and
	/// tags it. Every route ends here, so the path failure, the download failure and
	/// the finished line are written once instead of three times.
	private func save(
		_ track: Track,
		named filename: String,
		parentFolder: String,
		pathExtension: String,
		write: (URL) async throws -> Void
	) async -> Bool {
		guard let path = buildPath(baseLocation: .downloads, parentFolder: parentFolder, name: filename, pathExtension: pathExtension) else {
			displayError(title: "Error while downloading track", content: "Couldn't build path for track: \(track.title) -  \(track.artists.formArtistString())")
			return false
		}
		do {
			try await write(path)
		} catch {
			displayError(title: "Error while downloading track", content: "Download failed for track \(track.title). Error: \(error)")
			return false
		}
		await metadata.setMetadata(for: track, at: path)
		print("Download Finished: \(filename)")
		return true
	}

	public func download(tracks: [Track], parentFolder: String = "") async -> DownloadErrors {
		downloadStatus.startTask()
		defer { downloadStatus.finishTask() }

		var errors = DownloadErrors()
		for track in tracks {
			let success = await download(track: track, parentFolder: parentFolder, audioQuality: session.config.offlineAudioQuality)
			if !success {
				errors.affectedTracks.insert(track)
			}
		}
		print("Track Download Done!")
		return errors
	}

	public func download(video: Video, parentFolder: String = "") async -> Bool {
		guard let url = await video.videoUrl(session: session) else { return false }
		print("Downloading Video \(video.title)")
		let optionalPath = buildPath(baseLocation: .downloads, parentFolder: parentFolder, name: formFileName(video), pathExtension: "mp4")
		guard let path = optionalPath else {
			return false
		}
		do {
			try await Network.download(url, path: path, overwrite: true)
			return true
		} catch {
			return false
		}
//		metadataHandler.setMetadata(for: video, at: path)
		// TODO: Metadata for Videos
	}

	public func download(album: Album, parentFolder: String = "") async -> DownloadErrors {
		downloadStatus.startTask()
		defer { downloadStatus.finishTask() }

		guard let tracks = await session.albumTracks(albumId: album.id) else {
			return DownloadErrors(affectedAlbums: [album])
		}
		let artistString = album.artists != nil ? "\(album.artists!.formArtistString()) - " : ""
		return await download(tracks: tracks, parentFolder: "\(parentFolder.isEmpty ? "" : "\(parentFolder)/")\(artistString)\(album.title.replacingOccurrences(of: "/", with: ":"))")
	}

	public func downloadAllAlbums(from artist: Artist, parentFolder: String = "") async -> DownloadErrors {
		downloadStatus.startTask()
		defer { downloadStatus.finishTask() }

		guard let albums = await session.artistAlbums(artistId: artist.id) else {
			return DownloadErrors(affectedArtists: [artist])
		}
		var error = DownloadErrors()
		for album in albums {
			let r = await download(album: album, parentFolder: "\(parentFolder.isEmpty ? "" : "\(parentFolder)/")\(artist.name)")
			error.affectedAlbums.formUnion(r.affectedAlbums)
			error.affectedTracks.formUnion(r.affectedTracks)
		}
		return error
	}

	public func download(playlist: Playlist, parentFolder: String = "") async -> DownloadErrors {
		downloadStatus.startTask()
		defer { downloadStatus.finishTask() }

		guard let tracks = await session.playlistTracks(playlistId: playlist.uuid) else {
			return DownloadErrors(affectedPlaylists: [playlist])
		}
		let errors = await download(tracks: tracks, parentFolder: "\(parentFolder.isEmpty ? "" : "\(parentFolder)/")\(playlist.title)")
		return errors
	}
}

/// Sanitizes a single path component derived from untrusted API data (e.g. a title).
/// Removes path separators, `..` sequences, leading dots and control characters.
private func sanitizedPathComponent(_ component: String) -> String {
	var sanitized = component
		.replacingOccurrences(of: "/", with: ":")
		.replacingOccurrences(of: "\\", with: ":")
		.replacingOccurrences(of: "..", with: "")
	sanitized = sanitized.components(separatedBy: .controlCharacters).joined()
	sanitized = String(sanitized.drop(while: { $0 == "." }))
	return sanitized
}

/// Sanitizes a parent folder path. `/` separators between components are kept,
/// but every component is sanitized individually, so `..` can't escape the root.
private func sanitizedParentFolder(_ parentFolder: String) -> String {
	parentFolder
		.split(separator: "/", omittingEmptySubsequences: true)
		.map { sanitizedPathComponent(String($0)) }
		.filter { !$0.isEmpty }
		.joined(separator: "/")
}

func buildPath(baseLocation: DownloadLocation, parentFolder: String?, name: String, pathExtension: String?) -> URL? {

//	if !parentFolder.isEmpty {
//		if URL(string: parentFolder) == nil {
//			displayError(title: "Download Error", content: "Target Path '\(targetPath)' is not valid")
//			return nil
//		}
//	}
//	if URL(string: name) == nil {
//		displayError(title: "Download Error", content: "Name '\(name)' is not valid")
//		return nil
//	}
	// TODO: Doesn't work as intended, because URL doesn't allow whitespace, but should

	var path: URL
	do {
		switch baseLocation {
		case .downloads:
			path = try FileManager.default.url(for: .downloadsDirectory,
											   in: .userDomainMask,
											   appropriateFor: nil,
											   create: false)
		case .music:
			path = try FileManager.default.url(for: .musicDirectory,
											   in: .userDomainMask,
											   appropriateFor: nil,
											   create: false)
		}
		let root = path
		if let parentFolder = parentFolder {
			let sanitizedFolder = sanitizedParentFolder(parentFolder)
			if !sanitizedFolder.isEmpty {
				path.appendPathComponent(sanitizedFolder)
			}
		}
		path.appendPathComponent(sanitizedPathComponent(name))
		if let pathExtension = pathExtension {
			path.appendPathExtension(pathExtension)
		}
		// Defense in depth: never return a path outside of the download root.
		let rootPath = root.standardizedFileURL.path
		let resolvedPath = path.standardizedFileURL.path
		guard resolvedPath.hasPrefix(rootPath + "/") else {
			displayError(title: "Path Building Error", content: "Refusing to build path outside of download root: \(name)")
			return nil
		}
	} catch {
		displayError(title: "Path Building Error", content: "File Error: \(error)")
		return nil
	}
	return path
}
