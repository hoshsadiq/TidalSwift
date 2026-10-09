//
//  Track.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation
import SwiftUI

struct Tracks: Decodable {
	let limit: Int
	let offset: Int
	let totalNumberOfItems: Int
	let items: [Track]
}

public struct TrackMixes: Codable {
	public let trackMix: String?

	enum CodingKeys: String, CodingKey {
		case trackMix = "TRACK_MIX"
	}
}

public struct Track: Codable, Equatable, Identifiable, Hashable {
	public let id: Int
	public let title: String
	public let duration: Int
	public let replayGain: Float
	public let peak: Float?
	public let allowStreaming: Bool
	public let streamReady: Bool
	public let streamStartDate: Date?
	public let premiumStreamingOnly: Bool?
	public let trackNumber: Int
	public let volumeNumber: Int
	public let version: String?
	public let popularity: Int
	public let copyright: String?
	public let description: String?
	public let url: URL
	public let isrc: String?
	public let editable: Bool
	public let explicit: Bool
	public let audioQuality: AudioQuality?
	public let audioModes: [AudioMode]?
	/// Defaulted so the long memberwise initialiser call sites stay unchanged; the field
	/// only matters for tracks built from a payload that carries it.
	public var mediaMetadata: MediaMetadata? = nil
	public let artist: Artist?
	public let artists: [Artist]
	public let album: Album
	public let mixes: TrackMixes?
	public let dateAdded: Date?
	public let index: Int?
	public let itemUuid: UUID?
	public let bpm: Int?
	public let key: String?
	public let keyScale: String?

	/// Musical key converted to Camelot notation (e.g. "11A", "7B"), or "-" when unknown.
	public var camelotKey: String {
		guard let key else { return "-" }
		let normalized = Track.normalizeKey(key)
		switch keyScale?.uppercased() {
		case "MAJOR":
			return Track.majorCamelot[normalized] ?? "-"
		case "MINOR":
			return Track.minorCamelot[normalized] ?? "-"
		default:
			return "-"
		}
	}

	private static let majorCamelot: [String: String] = [
		"C": "8B", "G": "9B", "D": "10B", "A": "11B", "E": "12B", "B": "1B",
		"F#": "2B", "C#": "3B", "G#": "4B", "D#": "5B", "A#": "6B", "F": "7B"
	]

	private static let minorCamelot: [String: String] = [
		"A": "8A", "E": "9A", "B": "10A", "F#": "11A", "C#": "12A", "G#": "1A",
		"D#": "2A", "A#": "3A", "F": "4A", "C": "5A", "G": "6A", "D": "7A"
	]

	private static func normalizeKey(_ key: String) -> String {
		let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		let flats: [String: String] = [
			"DB": "C#", "EB": "D#", "GB": "F#", "AB": "G#", "BB": "A#",
			"CB": "B", "FB": "E"
		]
		return flats[trimmed] ?? trimmed
	}

	public func isInFavorites(session: Session) async -> Bool? {
		await session.favorites?.doFavoritesContainTrack(trackId: id)
	}

	public func getCoverUrl(session: Session, resolution: Int) -> URL? {
		album.getCoverUrl(session: session, resolution: resolution)
	}

	public func getCredits(session: Session) async -> [Credit]? {
		await session.trackCredits(trackId: id)
	}

	public var hasDolbyAtmos: Bool {
		audioModes?.contains(.dolbyAtmos) ?? false
	}

	/// A track can advertise hi-res even though the playback endpoints answer a
	/// `HI_RES_LOSSLESS` request with 44,1 kHz / 16 Bit. Showing the marker is honest;
	/// claiming the audio is hi-res would not be. See `AudioQuality.max`.
	public var hasHiRes: Bool {
		mediaMetadata?.tags.contains("HIRES_LOSSLESS") ?? false
	}
	public var hasStereo: Bool {
		guard let audioModes else { return true }
		return audioModes.contains(.stereo) || audioModes.contains(.mono)
	}

	/// Sony 360 Reality Audio can't be played, so a track needs at least one other mode
	public var isPlayable: Bool {
		streamReady && (audioModes?.contains { $0 != .sony360RealityAudio } ?? true)
	}

	/// Dolby Atmos is used when preferred or when the track has no stereo version.
	///
	/// Atmos is also gated on the ceiling (`AudioQuality.admitsDolbyAtmos`): a Low or Medium
	/// ceiling never asks for the ~768 kbps E-AC-3 rendition. The served tier is carried on the
	/// stream, so a `HI_RES_LOSSLESS` request the endpoint downgrades is named for what it holds.
	public func audioStream(session: Session, audioQuality: AudioQuality, preferDolbyAtmos: Bool) async -> AudioStream? {
		if hasDolbyAtmos, audioQuality.admitsDolbyAtmos, preferDolbyAtmos || !hasStereo {
			if let url = await session.dolbyAtmosUrl(trackId: id) {
				return AudioStream(url: url, pathExtension: "m4a", isDolbyAtmos: true)
			}
			if !hasStereo {
				return nil
			}
		}
		let servedQuality = audioQuality.servedByDirectStream(advertised: self.audioQuality)
		if let url = await session.audioUrl(trackId: id, audioQuality: audioQuality) {
			return AudioStream(
				url: url,
				// The extension describes the bytes, and the bytes are the served tier's: a Max
				// request on a track advertised 320 kbps is answered below High, so naming it
				// `.flac` from the request would store AAC-in-MP4 under a FLAC name, which the
				// offline FLAC check then refuses on every sync. The offline marker uses the same
				// served tier (`Offline.fileMarker`), so name and marker agree.
				pathExtension: session.pathExtension(for: servedQuality),
				isDolbyAtmos: false,
				quality: servedQuality
			)
		}
		// `streamUrl` refuses an Atmos-capable track at every tier (HTTP 401,
		// subStatus 4005 "Asset is not ready for playback"), and Tidal answers the
		// same track through the manifest instead. Fall back at this tier only: the
		// file the offline sync writes is named for the tier this request serves
		// (`servedByDirectStream`), so asking a lower tier here would store a file
		// that claims a tier it does not hold.
		// The rendition is read from the manifest, never assumed from the request, and an Atmos
		// answer is refused when the ceiling does not admit it: the gate on the request below
		// cannot stop Tidal serving Atmos at any quality. A refused answer returns nil, so a
		// track with no other rendition is skipped at that ceiling.
		guard let manifest = await session.playbackManifestUrl(trackId: id, audioQuality: audioQuality, ceiling: audioQuality) else {
			return nil
		}
		return AudioStream(
			url: manifest.url,
			pathExtension: session.pathExtension(for: manifest.url, audioQuality: audioQuality),
			isDolbyAtmos: manifest.isDolbyAtmos,
			quality: manifest.isDolbyAtmos ? nil : servedQuality
		)
	}

	public func isOffline(session: Session) async -> Bool {
		session.helpers.offline.isTrackOffline(track: self)
	}

	public func radio(session: Session) async -> [Track]? {
		await session.trackRadio(trackId: id)
	}

	public static func == (lhs: Track, rhs: Track) -> Bool {
		lhs.id == rhs.id
	}

	public func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}

/// A stream URL resolved for a track: which URL plays, what extension it serves, and
/// whether it is the Dolby Atmos rendition.
public struct AudioStream {
	/// The URL to play.
	public let url: URL
	/// The extension the URL serves, used when the stream is saved to disk.
	public let pathExtension: String
	/// Whether the stream is the Dolby Atmos rendition.
	public let isDolbyAtmos: Bool
	/// The stereo tier the stream holds, when the source knows it. A `streamUrl` request is
	/// answered with a lower tier than asked (a `HI_RES_LOSSLESS` request gets the 16-bit
	/// lossless file), and an offline file's tier is read from its name, so this is the served
	/// tier, never the requested one. `nil` for the Atmos rendition and for an unnamed legacy file.
	public let quality: AudioQuality?

	public init(url: URL, pathExtension: String, isDolbyAtmos: Bool, quality: AudioQuality? = nil) {
		self.url = url
		self.pathExtension = pathExtension
		self.isDolbyAtmos = isDolbyAtmos
		self.quality = quality
	}
}

struct AudioUrl: Decodable {
	let url: URL
	let trackId: Int
	let soundQuality: AudioQuality
	let encryptionKey: String
	let codec: String
}

/// Response of `/tracks/{id}/playbackinfopostpaywall`. High and Low answer with a DASH
/// manifest, which AVPlayer cannot play, so only the BTS payload is used; the Atmos
/// rendition arrives here too.
struct TrackPlaybackInfo: Decodable {
	let audioMode: AudioMode?
	let manifestMimeType: String
	let manifest: String
}

/// The BTS (Bento) manifest: a base64-encoded JSON payload with a direct stream URL.
struct BTSManifest: Decodable {
	let mimeType: String?
	let codecs: String?
	let encryptionType: String?
	let urls: [URL]
}

public enum TrackSorting: Int, Codable {
	case dateAdded // to Favorites
	case title
	case artists
	case album
	case duration
	case popularity
	case albumReleaseDate
}

extension Array where Element == Track {
	public func sortedTracks(by sorting: TrackSorting) -> [Track] {
		switch sorting {
		case .dateAdded:
			return self
		case .title:
			return self.sorted { $0.title.lowercased() < $1.title.lowercased() }
		case .artists:
			return self.sorted {
				($0.artists.formArtistString().lowercased(), $0.title.lowercased()) <
					($1.artists.formArtistString().lowercased(), $1.title.lowercased())
			}
		case .album:
			return self.sorted {
				($0.album.title.lowercased(), $0.title.lowercased()) <
					($1.album.title.lowercased(), $1.title.lowercased())
			}
		case .duration:
			return self.sorted {
				($0.duration, $0.title.lowercased()) <
					($1.duration, $1.title.lowercased())
			}
		case .popularity:
			return self.sorted {
				($0.popularity, $0.title.lowercased()) <
					($1.popularity, $1.title.lowercased())
			}
		case .albumReleaseDate:
			return self.sorted {
				($0.album.releaseDate ?? Date.distantPast, $0.title.lowercased()) <
					($1.album.releaseDate ?? Date.distantPast, $1.title.lowercased())
			}
		}
	}
}
