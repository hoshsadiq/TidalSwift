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

	public func audioUrl(session: Session, audioQuality: AudioQuality) async -> URL? {
		await session.audioUrl(trackId: id, audioQuality: audioQuality)
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

struct AudioUrl: Decodable {
	let url: URL
	let trackId: Int
	let soundQuality: AudioQuality
	let encryptionKey: String
	let codec: String
}

/// Response of `/tracks/{id}/playbackinfopostpaywall`. Hi-res answers with a DASH
/// manifest, which AVPlayer cannot play, so only the BTS payload is used.
struct TrackPlaybackInfo: Decodable {
	let manifestMimeType: String
	let manifest: String
}

/// The BTS (Bento) manifest: a base64-encoded JSON payload with a direct stream URL.
struct BTSManifest: Decodable {
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
