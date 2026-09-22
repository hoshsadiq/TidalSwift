//
//  CollectionV2.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

// MARK: - Collection mixes (v2)

/// A page of the user's collection mixes (`/v2/my-collection/mixes`).
///
/// Tolerant like the feed models: a malformed element is dropped instead of
/// failing the whole page.
public struct CollectionMixPage: Codable {
	public let items: [CollectionMixItem]
	public let cursor: String?
	public let lastModifiedAt: String?

	private enum CodingKeys: String, CodingKey {
		case items, cursor, lastModifiedAt
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		items = (try? container.decode(LossyArray<CollectionMixItem>.self, forKey: .items))?.elements ?? []
		cursor = try? container.decodeIfPresent(String.self, forKey: .cursor)
		lastModifiedAt = try? container.decodeIfPresent(String.self, forKey: .lastModifiedAt)
	}
}

/// A single entry of the collection mixes list.
///
/// The v2 API wraps the mix payload in `data`; the display strings live in
/// `titleTextInfo`/`subTitleTextInfo` (which may be absent) and the artwork in
/// `images`/`detailImages`. An entry without a decodable `data` payload can't
/// be rendered, so it fails decoding and is dropped by the lossy page.
public struct CollectionMixItem: Codable, Identifiable {
	public let trn: String?
	public let itemType: String?
	public let addedAt: Date?
	public let name: String?
	public let data: CollectionMixData

	public var id: String { data.id }

	private enum CodingKeys: String, CodingKey {
		case trn, itemType, addedAt, name, data
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		trn = try? container.decodeIfPresent(String.self, forKey: .trn)
		itemType = try? container.decodeIfPresent(String.self, forKey: .itemType)
		addedAt = try? container.decodeIfPresent(Date.self, forKey: .addedAt)
		name = try? container.decodeIfPresent(String.self, forKey: .name)
		data = try container.decode(CollectionMixData.self, forKey: .data)
	}
}

/// The `data` payload of a `CollectionMixItem`.
public struct CollectionMixData: Codable, Identifiable {
	public let id: String
	public let mixType: MixType?
	public let title: String?
	public let subTitle: String?
	public let titleTextInfo: HomeFeedTextInfo?
	public let subTitleTextInfo: HomeFeedTextInfo?
	public let images: CollectionMixImages?
	public let detailImages: CollectionMixImages?
	public let master: Bool?

	private enum CodingKeys: String, CodingKey {
		case id, mixType, title, subTitle, titleTextInfo, subTitleTextInfo
		case images, master
		case detailImages = "detailMixImages"
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		mixType = try? container.decodeIfPresent(MixType.self, forKey: .mixType)
		title = try? container.decodeIfPresent(String.self, forKey: .title)
		subTitle = try? container.decodeIfPresent(String.self, forKey: .subTitle)
		titleTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .titleTextInfo)
		subTitleTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .subTitleTextInfo)
		images = try? container.decodeIfPresent(CollectionMixImages.self, forKey: .images)
		detailImages = try? container.decodeIfPresent(CollectionMixImages.self, forKey: .detailImages)
		master = try? container.decodeIfPresent(Bool.self, forKey: .master)
	}

	/// Display title, preferring the plain `title` and falling back to `titleTextInfo.text`.
	public var displayTitle: String { title ?? titleTextInfo?.text ?? "" }
	/// Display subtitle, preferring the plain `subTitle` and falling back to `subTitleTextInfo.text`.
	public var displaySubtitle: String { subTitle ?? subTitleTextInfo?.text ?? "" }

	/// The mix as the existing `MixesItem` card model, so the app can reuse its
	/// mix cards. The text colours ride along so a card can draw the title and
	/// subtitle over the artwork in the API's colours.
	public var asMixesItem: MixesItem {
		MixesItem(
			id: id,
			title: displayTitle,
			subTitle: displaySubtitle,
			graphic: nil,
			images: MixesImages(
				small: images?.small.map { MixesImage(url: $0.url, width: $0.width, height: $0.height) },
				medium: images?.medium.map { MixesImage(url: $0.url, width: $0.width, height: $0.height) },
				large: images?.large.map { MixesImage(url: $0.url, width: $0.width, height: $0.height) }
			),
			mixType: mixType ?? .unknown,
			titleColor: titleTextInfo?.color,
			subtitleColor: subTitleTextInfo?.color
		)
	}
}

/// The `images` / `detailImages` of a collection mix: one entry per size.
public struct CollectionMixImages: Codable {
	public let small: CollectionMixImage?
	public let medium: CollectionMixImage?
	public let large: CollectionMixImage?

	enum CodingKeys: String, CodingKey {
		case small = "SMALL"
		case medium = "MEDIUM"
		case large = "LARGE"
	}
}

/// One image of a collection mix.
public struct CollectionMixImage: Codable {
	public let size: String?
	public let url: URL
	public let width: Int?
	public let height: Int?
}

// MARK: - Mix collection changes (v2)

/// The response of `/v2/favorites/mixes/add|remove`.
///
/// Every field is optional: the success body shape is unverified (the route
/// was only proven with a failing id), so an unknown body must not fail
/// decoding — HTTP 200 alone counts as success at the call site.
public struct MixCollectionChange: Codable {
	public let addedItems: [String]?
	public let itemsNotAdded: [String]?
	public let deletedItems: [String]?
	public let itemsNotRemoved: [String]?
	public let lastModifiedAt: String?

	private enum CodingKeys: String, CodingKey {
		case addedItems, itemsNotAdded, deletedItems, itemsNotRemoved, lastModifiedAt
	}

	public init(from decoder: Decoder) throws {
		let container = try? decoder.container(keyedBy: CodingKeys.self)
		addedItems = try? container?.decodeIfPresent([String].self, forKey: .addedItems)
		itemsNotAdded = try? container?.decodeIfPresent([String].self, forKey: .itemsNotAdded)
		deletedItems = try? container?.decodeIfPresent([String].self, forKey: .deletedItems)
		itemsNotRemoved = try? container?.decodeIfPresent([String].self, forKey: .itemsNotRemoved)
		lastModifiedAt = try? container?.decodeIfPresent(String.self, forKey: .lastModifiedAt)
	}
}

// MARK: - Playlist items (v1)

/// The response of `/v1/playlists/{id}/items`.
///
/// The v1 route wraps each entry in `{cut, item, type}`; `item` is a plain
/// `Track`. A malformed entry is dropped instead of failing the page.
public struct PlaylistItemsPage: Codable {
	public let items: [PlaylistItem]

	private enum CodingKeys: String, CodingKey {
		case items
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		items = (try? container.decode(LossyArray<PlaylistItem>.self, forKey: .items))?.elements ?? []
	}
}

/// One entry of a v1 playlist-items page.
///
/// Everything is optional so an entry with an unexpected shape is skipped
/// rather than failing the page.
public struct PlaylistItem: Codable {
	public let cut: Int?
	public let item: Track?
	public let type: String?

	private enum CodingKeys: String, CodingKey {
		case cut, item, type
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		cut = try? container.decodeIfPresent(Int.self, forKey: .cut)
		item = try? container.decodeIfPresent(Track.self, forKey: .item)
		type = try? container.decodeIfPresent(String.self, forKey: .type)
	}
}
