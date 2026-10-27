//
//  Metadata.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 30.06.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation

/// Format-independent tags, written by `FLACTagWriter` and `MP4TagWriter`.
///
/// `withLyrics` exists because lyrics arrive after the track and album records: fetching them
/// is a slower, best-effort path of its own, and a copy keeps that out of the tag mapping.
nonisolated struct AudioTags {
	var title: String
	var artist: String?
	var album: String
	var albumArtist: String?
	var trackNumber: Int
	var trackTotal: Int?
	var discNumber: Int
	var discTotal: Int?
	var releaseDate: String?
	var copyright: String?
	var isrc: String?
	var isCompilation: Bool
	var isExplicit: Bool
	var cover: Data?
	/// LRC text when the provider had timings, plain words otherwise. Embedded so the file
	/// carries its own lyrics, which is what an offline play reads back.
	var lyrics: String?

	func withLyrics(_ lyrics: String?) -> AudioTags {
		var copy = self
		copy.lyrics = lyrics
		return copy
	}
}

class Metadata {
	private unowned let session: Session

	init(session: Session) {
		self.session = session
	}

	func setMetadata(for track: Track, at path: URL) async {
		let tags = await tags(for: track)
		let tagsWithLyrics = tags.withLyrics(await lyricsText(for: track))
		do {
			switch path.pathExtension.lowercased() {
			case "flac":
				try await FLACTagWriter.write(tagsWithLyrics, to: path)
			case "m4a", "mp4":
				try await MP4TagWriter.write(tagsWithLyrics, to: path)
			default:
				print("Metadata: Unsupported file type \(path.pathExtension)")
			}
		} catch {
			displayError(title: "Error writing Metadata", content: "Path: \(path). Error: \(error)")
		}
	}

	private func tags(for track: Track) async -> AudioTags {
		let album = await session.album(albumId: track.album.id)
		let cover = await coverData(for: track)
		return Metadata.tags(for: track, album: album, cover: cover)
	}

	/// The lyrics to embed, from the resolver so a download reuses whatever the panel already
	/// fetched. Best effort: a download is not worth failing over lyrics.
	private func lyricsText(for track: Track) async -> String? {
		let outcome = await LyricsResolver(session: session).lyrics(
			for: track,
			preferLRCLIB: LyricsPreferences.useLRCLIBFallback
		)
		guard case .found(let result) = outcome else { return nil }
		// Timed lines go in as LRC so a reader gets the timings back, not a wall of words.
		return result.lines.isEmpty ? result.plainText : LRCWriter.encode(result.lines)
	}

	/// Maps a track and the album record to the tags the writers consume.
	static func tags(for track: Track, album: Album?, cover: Data?) -> AudioTags {
		var title = track.title
		if let version = track.version {
			title += " (\(version))"
		}

		var tags = AudioTags(
			title: title,
			artist: track.artists.isEmpty ? nil : track.artists.formArtistString(),
			album: track.album.title,
			trackNumber: track.trackNumber,
			discNumber: track.volumeNumber,
			releaseDate: track.album.releaseDate?.formatted(.iso8601.year().month().day()),
			copyright: track.copyright,
			isrc: track.isrc,
			isCompilation: track.album.isCompilation,
			isExplicit: track.explicit,
			lyrics: nil
		)

		// The album embedded in a track lacks most details.
		if let album {
			tags.trackTotal = album.numberOfTracks
			tags.discTotal = album.numberOfVolumes
			if let artists = album.artists, !artists.isEmpty {
				tags.albumArtist = artists.formArtistString()
			}
			if tags.releaseDate == nil {
				tags.releaseDate = album.releaseDate?.formatted(.iso8601.year().month().day())
			}
		}

		tags.cover = cover
		return tags
	}

	private func coverData(for track: Track) async -> Data? {
		guard let coverUrl = track.getCoverUrl(session: session, resolution: 1280) else { return nil }
		return await downloadCover(from: coverUrl)
	}

	private func downloadCover(from url: URL) async -> Data? {
		do {
			let (data, response) = try await URLSession.shared.data(from: url)
			if let statusCode = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(statusCode) {
				print("Metadata: Cover download failed with status \(statusCode)")
				return nil
			}
			return data
		} catch {
			print("Metadata: Cover download failed. Error: \(error)")
			return nil
		}
	}
}
