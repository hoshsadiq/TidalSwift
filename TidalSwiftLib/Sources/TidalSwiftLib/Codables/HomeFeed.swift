//
//  HomeFeed.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

// MARK: - Home feed (v2)

/// A v2 home feed page as returned by `/v2/home/feed/{slug}`.
///
/// Tolerant of unknown module and item types: `type` is kept as a `String` and
/// payloads that don't decode are left `nil` instead of failing the feed.
public struct HomeFeedV2: Codable {
	public let uuid: String?
	public let page: HomeFeedPage?
	public let header: HomeFeedHeader?
	public let items: [HomeFeedModule]

	private enum CodingKeys: String, CodingKey {
		case uuid, page, header, items
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
		page = try? container.decodeIfPresent(HomeFeedPage.self, forKey: .page)
		header = try? container.decodeIfPresent(HomeFeedHeader.self, forKey: .header)
		items = (try? container.decodeIfPresent([HomeFeedModule].self, forKey: .items)) ?? []
	}

	/// Creates a feed directly, e.g. to concatenate the pages of a paginated feed.
	public init(uuid: String?, page: HomeFeedPage?, header: HomeFeedHeader?, items: [HomeFeedModule]) {
		self.uuid = uuid
		self.page = page
		self.header = header
		self.items = items
	}
}

public struct HomeFeedPage: Codable {
	public let cursor: String?
}

public struct HomeFeedHeader: Codable {
	public let vibes: HomeFeedVibes?
}

public struct HomeFeedVibes: Codable {
	public let items: [HomeFeedVibe]
}

/// A feed tab (`For you`, `Staff Picks`, `Uploads`).
public struct HomeFeedVibe: Codable {
	public let name: String
	public let type: String
}

/// A single module (shelf) of a v2 home feed.
///
/// `type` is kept as a `String` so unknown types survive decoding.
public struct HomeFeedModule: Codable {
	public let type: String
	public let moduleId: String?
	public let title: String?
	public let subtitle: String?
	public let viewAll: String?
	public let items: [HomeFeedItem]

	private enum CodingKeys: String, CodingKey {
		case type, moduleId, title, subtitle, viewAll, items
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		type = (try? container.decode(String.self, forKey: .type)) ?? ""
		moduleId = try? container.decodeIfPresent(String.self, forKey: .moduleId)
		title = try? container.decodeIfPresent(String.self, forKey: .title)
		subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
		viewAll = try? container.decodeIfPresent(String.self, forKey: .viewAll)
		items = (try? container.decodeIfPresent([HomeFeedItem].self, forKey: .items)) ?? []
	}
}

/// A v2 "view all" page as returned by `/v2/{module.viewAll}`.
public struct HomeFeedViewAll: Codable {
	public let title: String?
	public let subtitle: String?
	public let itemLayout: String?
	public let filters: [String]?
	public let description: String?
	public let items: [HomeFeedItem]

	private enum CodingKeys: String, CodingKey {
		case title, subtitle, itemLayout, filters, description, items
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		title = try? container.decodeIfPresent(String.self, forKey: .title)
		subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
		itemLayout = try? container.decodeIfPresent(String.self, forKey: .itemLayout)
		filters = try? container.decodeIfPresent([String].self, forKey: .filters)
		description = try? container.decodeIfPresent(String.self, forKey: .description)
		items = (try? container.decodeIfPresent([HomeFeedItem].self, forKey: .items)) ?? []
	}
}

// MARK: - HomeFeedItem

/// A single item of a `HomeFeedModule` or `HomeFeedViewAll`.
///
/// The v2 API wraps the payload in `data` and names its kind in `type`. Unknown
/// kinds decode fine (the raw string is kept) and a payload that doesn't decode
/// is left `nil` instead of failing the feed.
public struct HomeFeedItem: Codable {
	/// Discriminator: `MIX`, `ALBUM`, `TRACK`, `ARTIST`, `PLAYLIST`, …
	public let type: String
	public let following: Bool?
	public let numberOfFollowers: Int?

	public let mix: HomeFeedMix?
	public let album: HomeFeedAlbum?
	public let track: HomeFeedTrack?
	public let artist: Artist?
	public let playlist: HomeFeedPlaylist?
	public let magazine: HomeFeedMagazine?

	private enum CodingKeys: String, CodingKey {
		case type, following, numberOfFollowers, data
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		type = (try? container.decode(String.self, forKey: .type)) ?? ""
		following = try? container.decodeIfPresent(Bool.self, forKey: .following)
		numberOfFollowers = try? container.decodeIfPresent(Int.self, forKey: .numberOfFollowers)

		let payloadDecoder: Decoder
		if container.contains(.data) {
			payloadDecoder = (try? container.superDecoder(forKey: .data)) ?? decoder
		} else {
			payloadDecoder = decoder
		}

		var mix: HomeFeedMix?
		var album: HomeFeedAlbum?
		var track: HomeFeedTrack?
		var artist: Artist?
		var playlist: HomeFeedPlaylist?
		var magazine: HomeFeedMagazine?
		switch type {
		case "MIX":
			mix = try? HomeFeedMix(from: payloadDecoder)
		case "ALBUM":
			album = try? HomeFeedAlbum(from: payloadDecoder)
		case "TRACK":
			track = try? HomeFeedTrack(from: payloadDecoder)
		case "ARTIST":
			artist = try? Artist(from: payloadDecoder)
		case "PLAYLIST":
			playlist = try? HomeFeedPlaylist(from: payloadDecoder)
		case "MAGAZINE":
			magazine = try? HomeFeedMagazine(from: payloadDecoder)
		default:
			break
		}
		self.mix = mix
		self.album = album
		self.track = track
		self.artist = artist
		self.playlist = playlist
		self.magazine = magazine
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(type, forKey: .type)
		try container.encodeIfPresent(following, forKey: .following)
		try container.encodeIfPresent(numberOfFollowers, forKey: .numberOfFollowers)
		if let mix {
			try container.encode(mix, forKey: .data)
		} else if let album {
			try container.encode(album, forKey: .data)
		} else if let track {
			try container.encode(track, forKey: .data)
		} else if let artist {
			try container.encode(artist, forKey: .data)
		} else if let playlist {
			try container.encode(playlist, forKey: .data)
		} else if let magazine {
			try container.encode(magazine, forKey: .data)
		}
	}
}

// MARK: - HomeFeedMix

/// A v2 mix payload.
///
/// Unlike `MixesItem`, the v2 API carries the display strings in
/// `titleTextInfo` / `subtitleTextInfo` and the artwork in `mixImages`.
public struct HomeFeedMix: Codable, Identifiable {
	public let id: String
	/// Raw v2 mix type (e.g. `DISCOVERY_MIX`); unknown values survive.
	public let type: String
	/// The v2 `type` mapped through the tolerant `MixType` decoder.
	public let mixType: MixType
	public let titleTextInfo: HomeFeedTextInfo?
	public let subtitleTextInfo: HomeFeedTextInfo?
	public let shortSubtitleTextInfo: HomeFeedTextInfo?
	public let descriptionTextInfo: HomeFeedTextInfo?
	public let mixNumber: Int?
	public let userId: Int?
	public let artists: [Artist]?
	public let mixImages: [HomeFeedMixImage]
	public let detailMixImages: [HomeFeedMixImage]?

	/// Display title (`titleTextInfo.text`).
	public var title: String { titleTextInfo?.text ?? "" }
	/// Display subtitle (`subtitleTextInfo.text`).
	public var subTitle: String { subtitleTextInfo?.text ?? "" }
	public var shortSubtitle: String? { shortSubtitleTextInfo?.text }
	/// Display description (`description.text`).
	public var description: String? { descriptionTextInfo?.text }

	public var smallImage: HomeFeedMixImage? { mixImages.first { $0.size == "SMALL" } }
	public var mediumImage: HomeFeedMixImage? { mixImages.first { $0.size == "MEDIUM" } }
	public var largeImage: HomeFeedMixImage? { mixImages.first { $0.size == "LARGE" } }

	/// The mix as the existing `MixesItem` card model, so the app can reuse its
	/// mix cards. The text colours ride along like the collection adapter's, so
	/// the model never silently drops data the API sent.
	public var asMixesItem: MixesItem {
		MixesItem(
			id: id,
			title: title,
			subTitle: subTitle,
			graphic: nil,
			images: MixesImages(
				small: smallImage.map { MixesImage(url: $0.url, width: $0.width, height: $0.height) },
				medium: mediumImage.map { MixesImage(url: $0.url, width: $0.width, height: $0.height) },
				large: largeImage.map { MixesImage(url: $0.url, width: $0.width, height: $0.height) }
			),
			mixType: mixType,
			titleColor: titleTextInfo?.color,
			subtitleColor: subtitleTextInfo?.color
		)
	}

	private enum CodingKeys: String, CodingKey {
		case id, type, titleTextInfo, subtitleTextInfo, shortSubtitleTextInfo
		case descriptionTextInfo = "description"
		case mixNumber, userId, artists, mixImages, detailMixImages
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		type = (try? container.decode(String.self, forKey: .type)) ?? ""
		mixType = (try? container.decode(MixType.self, forKey: .type)) ?? .unknown
		titleTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .titleTextInfo)
		subtitleTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .subtitleTextInfo)
		shortSubtitleTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .shortSubtitleTextInfo)
		descriptionTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .descriptionTextInfo)
		mixNumber = try? container.decodeIfPresent(Int.self, forKey: .mixNumber)
		userId = try? container.decodeIfPresent(Int.self, forKey: .userId)
		artists = try? container.decodeIfPresent([Artist].self, forKey: .artists)
		mixImages = (try? container.decodeIfPresent([HomeFeedMixImage].self, forKey: .mixImages)) ?? []
		detailMixImages = try? container.decodeIfPresent([HomeFeedMixImage].self, forKey: .detailMixImages)
	}
}

/// A `{ text, color }` pair as used by v2 mix payloads.
public struct HomeFeedTextInfo: Codable {
	public let text: String?
	public let color: String?
}

/// One entry of a v2 mix's `mixImages` / `detailMixImages`.
public struct HomeFeedMixImage: Codable {
	public let size: String
	public let url: URL
	public let width: Int?
	public let height: Int?
}

// MARK: - HomeFeed item payloads

/// A v2 album payload.
///
/// The shared `Album` model can't decode these payloads: v2 sends
/// `streamStartDate` values like `1970-01-01T00`, which the shared date
/// formatter rejects. This is a tolerant subset instead.
public struct HomeFeedAlbum: Codable, Identifiable {
	public let id: Int
	public let title: String
	public let artists: [Artist]?
	public let duration: Int?
	public let cover: String?
	public let videoCover: String?
	public let numberOfTracks: Int?
	public let numberOfVideos: Int?
	public let numberOfVolumes: Int?
	public let releaseDate: Date?
	public let type: String?
	public let version: String?
	public let explicit: Bool?
	public let popularity: Int?
	public let audioQuality: AudioQuality?
	public let audioModes: [AudioMode]?
	public let streamReady: Bool?
	public let allowStreaming: Bool?
	public let upc: String?
	public let copyright: String?
	public let url: URL?
	public let vibrantColor: String?
}

/// A v2 track payload.
///
/// The shared `Track` model can't decode these payloads: v2 omits required
/// fields (`url`) and sends `streamStartDate` values like `2026-09-11T00`.
public struct HomeFeedTrack: Codable, Identifiable {
	public let id: Int
	public let title: String
	public let album: HomeFeedAlbum?
	public let artists: [Artist]?
	public let duration: Int?
	public let version: String?
	public let explicit: Bool?
	public let audioQuality: AudioQuality?
	public let audioModes: [AudioMode]?
	public let popularity: Int?
	public let copyright: String?
	public let isrc: String?
	public let trackNumber: Int?
	public let volumeNumber: Int?
	public let replayGain: Float?
	public let peak: Float?
	public let allowStreaming: Bool?
	public let streamReady: Bool?
	public let editable: Bool?
	/// Whether the track is an independent upload (TIDAL marks these with an ↑ badge).
	public let upload: Bool?
	public let mixes: TrackMixes?
	public let audioAnalysisAttributes: HomeFeedAudioAnalysisAttributes?
}

/// v2 track audio analysis (`bpm` is a string here, unlike the v1 track detail).
public struct HomeFeedAudioAnalysisAttributes: Codable {
	public let bpm: String?
	public let key: String?
	public let keyScale: String?
}

/// A v2 playlist payload.
///
/// The shared `Playlist` model can't decode these payloads: v2 omits required
/// fields (`popularity`, `publicPlaylist`).
public struct HomeFeedPlaylist: Codable, Identifiable {
	public var id: String { uuid }

	public let uuid: String
	public let title: String
	public let description: String?
	public let type: String?
	public let creator: PlaylistCreator?
	public let numberOfTracks: Int?
	public let numberOfVideos: Int?
	public let duration: Int?
	public let lastUpdated: Date?
	public let created: Date?
	public let image: String?
	public let squareImage: String?
	public let url: URL?
	public let promotedArtists: [Artist]?
	public let sharingLevel: String?
	public let status: String?
	public let source: String?
	public let trn: String?
}

// MARK: - HomeFeedMagazine

/// A v2 magazine payload, used by the Staff Picks "Editorial Radar" and "Tidal
/// Magazine" shelves and the Uploads "Featured" shelf.
///
/// `type` is the *content* kind (`ALBUM`, `EXTURL`, `CATEGORY_PAGES`,
/// `PLAYLIST`, …) and `artifactId` its identifier: an album id, an article URL,
/// a curated page path or a playlist uuid. Unknown kinds survive decoding so a
/// future flavour can't break the shelf around it.
public struct HomeFeedMagazine: Codable, Identifiable {
	public let id: Int
	public let imageURL: URL?
	public let artifactId: String
	public let type: String
	public let header: String?
	public let shortHeader: String?
	public let shortSubHeader: String?
	public let groupName: String?
	public let priority: Int?

	private enum CodingKeys: String, CodingKey {
		case id, imageURL, artifactId, type, header, shortHeader, shortSubHeader
		case groupName, priority
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(Int.self, forKey: .id)
		imageURL = try? container.decodeIfPresent(URL.self, forKey: .imageURL)
		artifactId = (try? container.decode(String.self, forKey: .artifactId)) ?? ""
		type = (try? container.decode(String.self, forKey: .type)) ?? ""
		header = try? container.decodeIfPresent(String.self, forKey: .header)
		shortHeader = try? container.decodeIfPresent(String.self, forKey: .shortHeader)
		shortSubHeader = try? container.decodeIfPresent(String.self, forKey: .shortSubHeader)
		groupName = try? container.decodeIfPresent(String.self, forKey: .groupName)
		priority = try? container.decodeIfPresent(Int.self, forKey: .priority)
	}
}

// MARK: - HomeFeed payload → shared model adapters

// v2 payloads are tolerant subsets of the shared models: they omit fields the
// feed API doesn't return. These adapters let the app reuse the existing
// `*GridItem` cards (which take the shared models) by filling the missing
// fields with safe defaults.

extension Album {
	/// Minimal album for v2 track payloads that lack a nested album.
	fileprivate static var empty: Album {
		Album(
			id: 0,
			title: "",
			duration: nil,
			streamReady: nil,
			streamStartDate: nil,
			allowStreaming: nil,
			premiumStreamingOnly: nil,
			numberOfTracks: nil,
			numberOfVideos: nil,
			numberOfVolumes: nil,
			releaseDate: nil,
			copyright: nil,
			type: nil,
			version: nil,
			url: nil,
			cover: nil,
			videoCover: nil,
			explicit: nil,
			upc: nil,
			popularity: nil,
			audioQuality: nil,
			audioModes: nil,
			artist: nil,
			artists: nil
		)
	}
}

extension HomeFeedAlbum {
	/// The album as the shared `Album` model.
	///
	/// v2 has no `streamStartDate`, `premiumStreamingOnly` or `artist` (singular)
	/// and `Album` has no `vibrantColor`, so those stay `nil`.
	public var asAlbum: Album {
		Album(
			id: id,
			title: title,
			duration: duration,
			streamReady: streamReady,
			streamStartDate: nil,
			allowStreaming: allowStreaming,
			premiumStreamingOnly: nil,
			numberOfTracks: numberOfTracks,
			numberOfVideos: numberOfVideos,
			numberOfVolumes: numberOfVolumes,
			releaseDate: releaseDate,
			copyright: copyright,
			type: type,
			version: version,
			url: url,
			cover: cover,
			videoCover: videoCover,
			explicit: explicit,
			upc: upc,
			popularity: popularity,
			audioQuality: audioQuality,
			audioModes: audioModes,
			artist: nil,
			artists: artists
		)
	}
}

extension HomeFeedTrack {
	/// The track as the shared `Track` model.
	///
	/// v2 has no `url` (the canonical web URL is used instead) and no
	/// `replayGain` (defaults to 0). `streamStartDate`, `premiumStreamingOnly`,
	/// `description`, `artist` (singular), `dateAdded`, `index` and `itemUuid`
	/// stay `nil`.
	public var asTrack: Track {
		Track(
			id: id,
			title: title,
			duration: duration ?? 0,
			replayGain: replayGain ?? 0,
			peak: peak,
			allowStreaming: allowStreaming ?? false,
			streamReady: streamReady ?? false,
			streamStartDate: nil,
			premiumStreamingOnly: nil,
			trackNumber: trackNumber ?? 0,
			volumeNumber: volumeNumber ?? 0,
			version: version,
			popularity: popularity ?? 0,
			copyright: copyright,
			description: nil,
			url: URL(string: "https://tidal.com/browse/track/\(id)")!,
			isrc: isrc,
			editable: editable ?? false,
			explicit: explicit ?? false,
			audioQuality: audioQuality,
			audioModes: audioModes,
			artist: nil,
			artists: artists ?? [],
			album: album?.asAlbum ?? .empty,
			mixes: mixes,
			dateAdded: nil,
			index: nil,
			itemUuid: nil,
			bpm: audioAnalysisAttributes?.bpm.flatMap(Double.init).map(Int.init),
			key: audioAnalysisAttributes?.key,
			keyScale: audioAnalysisAttributes?.keyScale
		)
	}
}

extension HomeFeedPlaylist {
	/// The playlist as the shared `Playlist` model.
	///
	/// v2 has no `popularity` (defaults to 0) and no `publicPlaylist` (derived
	/// from `sharingLevel == "PUBLIC"`). `creator`, `url`, `lastUpdated`,
	/// `created`, `numberOfTracks`, `numberOfVideos` and `duration` fall back to
	/// safe defaults when absent.
	public var asPlaylist: Playlist {
		Playlist(
			uuid: uuid,
			title: title,
			numberOfTracks: numberOfTracks ?? 0,
			numberOfVideos: numberOfVideos ?? 0,
			creator: creator ?? PlaylistCreator(id: nil, name: nil, url: nil, picture: nil, popularity: nil),
			description: description,
			duration: duration ?? 0,
			lastUpdated: lastUpdated ?? Date.distantPast,
			created: created ?? Date.distantPast,
			type: PlaylistType(rawValue: type ?? "") ?? .editorial,
			publicPlaylist: sharingLevel == "PUBLIC",
			url: url ?? URL(string: "https://tidal.com/browse/playlist/\(uuid)")!,
			image: image,
			popularity: 0,
			squareImage: squareImage
		)
	}
}
