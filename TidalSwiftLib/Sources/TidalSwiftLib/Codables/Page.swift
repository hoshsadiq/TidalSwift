//
//  Page.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 16.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

// MARK: - Page

/// A Tidal page as returned by `/v1/pages/...`.
///
/// Tolerant of both the v1 shape (`rows` → `modules`) and the v2 shape
/// (`items`), and of unknown module and item types.
public struct Page: Codable {
	public let id: String?
	public let title: String?
	public let selfLink: URL?
	public let rows: [PageRow]?
	/// v2 shape.
	public let items: [PageItem]?

	/// All modules of all rows, flattened. Empty for v2 pages.
	public var modules: [PageModule] {
		rows?.flatMap(\.modules) ?? []
	}
}

public struct PageRow: Codable {
	public let modules: [PageModule]
}

/// A single module (shelf) of a page.
///
/// `type` is kept as a `String` so unknown types survive decoding; use
/// `knownType` to map it to `PageModuleType` for dispatch.
public struct PageModule: Codable {
	public let id: String?
	public let type: String
	public let title: String?
	public let description: String?
	/// Body text of a `TEXT_BLOCK` module.
	public let text: String?
	public let pagedList: PagedList?
	public let showMore: ShowMore?
	/// v2 shape: a plain path instead of a `showMore` object.
	public let viewAll: String?
	/// v2 shape.
	public let moduleId: String?
	public let subtitle: String?
	/// v2 shape, also used by v1 promotion modules (`MULTIPLE_TOP_PROMOTIONS`).
	public let items: [PageItem]?

	// Presentation hints used by Explore pages. All optional: most modules
	// omit them, and unknown values are kept as-is.
	public let listFormat: String?
	public let scroll: String?
	public let showTableHeaders: Bool?
	public let supportsPaging: Bool?
	public let quickPlay: Bool?
	public let layout: String?
	public let width: Int?
	public let preTitle: String?

	public var knownType: PageModuleType? {
		PageModuleType(rawValue: type)
	}
}

/// Known module types. Unknown types decode fine and map to `nil`.
public enum PageModuleType: String, Codable, CaseIterable {
	case albumList = "ALBUM_LIST"
	case artistList = "ARTIST_LIST"
	case trackList = "TRACK_LIST"
	case playlistList = "PLAYLIST_LIST"
	case videoList = "VIDEO_LIST"
	case mixList = "MIX_LIST"
	case mixedTypesList = "MIXED_TYPES_LIST"
	case highlightModule = "HIGHLIGHT_MODULE"
	case albumItems = "ALBUM_ITEMS"
	case itemListWithRoles = "ITEM_LIST_WITH_ROLES"
	case pageLinks = "PAGE_LINKS"
	case pageLinksCloud = "PAGE_LINKS_CLOUD"
	case featuredPromotions = "FEATURED_PROMOTIONS"
	case multipleTopPromotions = "MULTIPLE_TOP_PROMOTIONS"
	case mixHeader = "MIX_HEADER"
	case artistHeader = "ARTIST_HEADER"
	case albumHeader = "ALBUM_HEADER"
	case textBlock = "TEXT_BLOCK"
	case articleList = "ARTICLE_LIST"
	case social = "SOCIAL"
	// v2
	case shortcutList = "SHORTCUT_LIST"
	case horizontalList = "HORIZONTAL_LIST"
	case horizontalListWithContext = "HORIZONTAL_LIST_WITH_CONTEXT"
}

/// "View all" / "Show more" link of a module.
public struct ShowMore: Codable {
	public let apiPath: String
	public let title: String?
}

/// A pageable list of items. Also decodes the load-more response, which has no
/// `dataApiPath`.
public struct PagedList: Codable {
	public let dataApiPath: String?
	public let limit: Int?
	public let offset: Int?
	public let totalNumberOfItems: Int?
	public let items: [PageItem]
}

// MARK: - PageItem

/// A single item of a `PagedList` or module.
///
/// Tidal mixes item kinds within a single list and v1 items carry no reliable
/// discriminator, so every known payload is decoded best-effort: the matching
/// field is set, all others stay `nil`. Decoding never fails because a payload
/// doesn't fit.
public struct PageItem: Codable {
	/// Discriminator when the payload provides one (v2: `TRACK`, `PLAYLIST`, …;
	/// v1 playlists: `EDITORIAL`, …). Not present for every v1 kind.
	public let type: String?

	public let album: Album?
	public let playlist: PagePlaylist?
	public let artist: Artist?
	public let track: Track?
	public let video: PageVideo?
	public let mix: PageMix?

	/// v2 shape: nested items of a module item.
	public let items: [PageItem]?

	// Promotion items (`FEATURED_PROMOTIONS`, `MULTIPLE_TOP_PROMOTIONS`).
	public let artifactId: String?
	public let header: String?
	public let shortHeader: String?
	public let shortSubHeader: String?
	public let imageId: String?
	public let text: String?
	public let featured: Bool?

	// Link tiles (`PAGE_LINKS`, `PAGE_LINKS_CLOUD`, `SHORTCUT_LIST`).
	public let title: String?
	public let apiPath: String?
	public let icon: String?

	/// The kind of payload this item holds, if any.
	public var kind: PageItemKind? {
		if mix != nil { return .mix }
		if playlist != nil { return .playlist }
		if track != nil { return .track }
		if video != nil { return .video }
		if artist != nil { return .artist }
		if album != nil { return .album }
		// v2 wrappers name their payload type explicitly. Promotion items also
		// carry a `type`, but it describes the linked artifact, not a payload.
		if artifactId == nil, let type, let known = PageItemKind(rawValue: type) {
			return known
		}
		return nil
	}

	private enum CodingKeys: String, CodingKey {
		case type, data, items
		case artifactId, header, shortHeader, shortSubHeader, imageId, text, featured
		case title, apiPath, icon
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		type = try? container.decodeIfPresent(String.self, forKey: .type)
		items = try? container.decodeIfPresent([PageItem].self, forKey: .items)
		artifactId = try? container.decodeIfPresent(String.self, forKey: .artifactId)
		header = try? container.decodeIfPresent(String.self, forKey: .header)
		shortHeader = try? container.decodeIfPresent(String.self, forKey: .shortHeader)
		shortSubHeader = try? container.decodeIfPresent(String.self, forKey: .shortSubHeader)
		imageId = try? container.decodeIfPresent(String.self, forKey: .imageId)
		text = try? container.decodeIfPresent(String.self, forKey: .text)
		featured = try? container.decodeIfPresent(Bool.self, forKey: .featured)
		title = try? container.decodeIfPresent(String.self, forKey: .title)
		apiPath = try? container.decodeIfPresent(String.self, forKey: .apiPath)
		icon = try? container.decodeIfPresent(String.self, forKey: .icon)

		// v1 items are the payload itself; v2 wraps it in a `data` object.
		let payloadDecoder: Decoder
		if container.contains(.data) {
			payloadDecoder = (try? container.superDecoder(forKey: .data)) ?? decoder
		} else {
			payloadDecoder = decoder
		}
		album = try? Album(from: payloadDecoder)
		playlist = try? PagePlaylist(from: payloadDecoder)
		artist = try? Artist(from: payloadDecoder)
		track = try? Track(from: payloadDecoder)
		video = try? PageVideo(from: payloadDecoder)
		mix = try? PageMix(from: payloadDecoder)
	}

	public func encode(to encoder: Encoder) throws {
		// v1 items are the payload itself.
		if let mix {
			try mix.encode(to: encoder)
		} else if let playlist {
			try playlist.encode(to: encoder)
		} else if let track {
			try track.encode(to: encoder)
		} else if let video {
			try video.encode(to: encoder)
		} else if let artist {
			try artist.encode(to: encoder)
		} else if let album {
			try album.encode(to: encoder)
		} else {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encodeIfPresent(type, forKey: .type)
			try container.encodeIfPresent(artifactId, forKey: .artifactId)
			try container.encodeIfPresent(header, forKey: .header)
			try container.encodeIfPresent(shortHeader, forKey: .shortHeader)
			try container.encodeIfPresent(shortSubHeader, forKey: .shortSubHeader)
			try container.encodeIfPresent(imageId, forKey: .imageId)
			try container.encodeIfPresent(text, forKey: .text)
			try container.encodeIfPresent(featured, forKey: .featured)
			try container.encodeIfPresent(title, forKey: .title)
			try container.encodeIfPresent(apiPath, forKey: .apiPath)
			try container.encodeIfPresent(icon, forKey: .icon)
			try container.encodeIfPresent(items, forKey: .items)
		}
	}
}

/// Known item kinds. Unknown kinds decode fine and map to `nil`.
public enum PageItemKind: String, Codable {
	case album = "ALBUM"
	case playlist = "PLAYLIST"
	case artist = "ARTIST"
	case track = "TRACK"
	case video = "VIDEO"
	case mix = "MIX"
}

// MARK: - Page item payloads

/// A playlist as embedded in a page.
///
/// The full `Playlist` model requires fields (creator, created, lastUpdated, …)
/// that page payloads don't contain, so this is a tolerant subset.
public struct PagePlaylist: Codable, Identifiable {
	public var id: String { uuid }

	public let uuid: String
	public let title: String
	public let description: String?
	public let image: String?
	public let squareImage: String?
	public let numberOfTracks: Int?
	public let numberOfVideos: Int?
	public let duration: Int?
	public let type: String?
	public let url: URL?
	public let promotedArtists: [Artist]?
}

/// A video as embedded in a page.
///
/// The full `Video` model requires fields (quality, …) that page payloads don't
/// contain, so this is a tolerant subset.
public struct PageVideo: Codable, Identifiable {
	public let id: Int
	public let title: String
	public let duration: Int?
	public let imageId: String?
	public let releaseDate: Date?
	public let type: String?
	public let version: String?
	public let explicit: Bool?
	public let popularity: Int?
	public let streamReady: Bool?
	public let allowStreaming: Bool?
	public let artists: [Artist]?
}

/// A mix as embedded in a page.
///
/// Unlike `MixesItem`, page mixes carry their own `images` (SMALL/MEDIUM/LARGE)
/// instead of relying on `graphic`.
public struct PageMix: Codable, Identifiable {
	public let id: String
	public let title: String
	public let subTitle: String?
	public let shortSubtitle: String?
	public let description: String?
	public let mixType: String?
	public let images: PageMixImages?
}

public struct PageMixImages: Codable {
	public let small: PageMixImage?
	public let medium: PageMixImage?
	public let large: PageMixImage?

	enum CodingKeys: String, CodingKey {
		case small = "SMALL"
		case medium = "MEDIUM"
		case large = "LARGE"
	}
}

public struct PageMixImage: Codable {
	public let url: URL
	public let width: Int?
	public let height: Int?
}

// MARK: - Page payload → full model adapters

// Page payloads are tolerant subsets of the full models: they omit fields the
// page API doesn't return. These adapters let the app reuse the existing
// `*GridItem` cards (which take the full models) by filling the missing fields
// with safe defaults. `Album`, `Artist` and `Track` need no adapter because
// `PageItem` already carries the full models for those kinds.

extension Playlist {
	public init(pagePlaylist: PagePlaylist) {
		self.init(
			uuid: pagePlaylist.uuid,
			title: pagePlaylist.title,
			numberOfTracks: pagePlaylist.numberOfTracks ?? 0,
			numberOfVideos: pagePlaylist.numberOfVideos ?? 0,
			creator: PlaylistCreator(id: nil, name: nil, url: nil, picture: nil, popularity: nil),
			description: pagePlaylist.description,
			duration: pagePlaylist.duration ?? 0,
			lastUpdated: Date(),
			created: Date(),
			type: PlaylistType(rawValue: pagePlaylist.type ?? "") ?? .editorial,
			publicPlaylist: false,
			url: pagePlaylist.url ?? URL(string: "https://tidal.com")!,
			image: pagePlaylist.image,
			popularity: 0,
			squareImage: pagePlaylist.squareImage
		)
	}
}

extension Video {
	public init(pageVideo: PageVideo) {
		self.init(
			id: pageVideo.id,
			title: pageVideo.title,
			volumeNumber: 0,
			trackNumber: 0,
			releaseDate: pageVideo.releaseDate,
			imagePath: nil,
			imageId: pageVideo.imageId,
			duration: pageVideo.duration ?? 0,
			quality: "HIGH",
			streamReady: pageVideo.streamReady ?? false,
			streamStartDate: nil,
			allowStreaming: pageVideo.allowStreaming ?? false,
			explicit: pageVideo.explicit ?? false,
			popularity: pageVideo.popularity ?? 0,
			type: pageVideo.type ?? "Music Video",
			adsUrl: nil,
			adsPrePaywallOnly: false,
			artists: pageVideo.artists ?? []
		)
	}
}

extension MixesItem {
	public init(pageMix: PageMix) {
		self.init(
			id: pageMix.id,
			title: pageMix.title,
			subTitle: pageMix.subTitle ?? pageMix.shortSubtitle ?? "",
			graphic: nil,
			images: pageMix.images.map(MixesImages.init(pageImages:)),
			mixType: MixType(rawValue: pageMix.mixType ?? "") ?? .unknown
		)
	}
}

extension MixesImages {
	public init(pageImages: PageMixImages) {
		self.init(
			small: pageImages.small.map(MixesImage.init(pageImage:)),
			medium: pageImages.medium.map(MixesImage.init(pageImage:)),
			large: pageImages.large.map(MixesImage.init(pageImage:))
		)
	}
}

extension MixesImage {
	public init(pageImage: PageMixImage) {
		self.init(url: pageImage.url, width: pageImage.width, height: pageImage.height)
	}
}
