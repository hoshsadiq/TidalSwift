//
//  Feed.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

// MARK: - Feed activities (v2)

/// The response of `/v2/feed/activities`.
///
/// Activities are only created for events that happen *after* the user follows
/// an artist — there is no backfill, so a fresh follow yields an empty feed
/// until the artist releases something new.
public struct FeedResponse: Codable {
	public let activities: [FeedActivity]
	public let stats: FeedStats?

	private enum CodingKeys: String, CodingKey {
		case activities, stats
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// TIDAL adds activity types over time; one malformed entry must not
		// hide the rest of the feed, so decode element-by-element and drop
		// whatever fails.
		activities = (try? container.decode(LossyArray<FeedActivity>.self, forKey: .activities))?.elements ?? []
		stats = try? container.decodeIfPresent(FeedStats.self, forKey: .stats)
	}
}

/// Decodes an array while dropping elements that fail to decode.
///
/// Used for lists whose elements TIDAL may extend or change shape over time:
/// a single bad element must not fail the whole response.
struct LossyArray<Element: Decodable>: Decodable {
	let elements: [Element]

	init(from decoder: Decoder) throws {
		var container = try decoder.unkeyedContainer()
		var elements: [Element] = []
		while !container.isAtEnd {
			// Decode through `FailableDecodable`, not `try? Element(...)`: a
			// failed element decode leaves the container's index untouched and
			// the loop spins forever, while wrapping the failure makes the outer
			// decode succeed so the container always advances.
			if let element = try? container.decode(FailableDecodable<Element>.self).element {
				elements.append(element)
			}
		}
		self.elements = elements
	}
}

private struct FailableDecodable<Element: Decodable>: Decodable {
	let element: Element?

	init(from decoder: Decoder) throws {
		element = try? Element(from: decoder)
	}
}

/// The `stats` of a `FeedResponse`.
public struct FeedStats: Codable {
	public let totalNotSeenActivities: Int?
}

/// A single feed activity.
public struct FeedActivity: Codable {
	public let seen: Bool?
	public let followableActivity: FollowableActivity?

	/// Whether this activity carries a payload the app knows how to render.
	///
	/// TIDAL adds activity types over time and a known type can still arrive
	/// with a payload that didn't decode, so the Feed filters on this and falls
	/// back to releases when nothing is displayable.
	public var isDisplayable: Bool {
		guard let payload = followableActivity else { return false }
		switch payload.kind {
		case .newAlbumRelease:
			return payload.album != nil
		case .newHistoryMix:
			return payload.historyMix != nil
		case .unknown:
			return false
		}
	}
}

/// The payload of a `FeedActivity`.
///
/// `activityType` stays a `String` so unknown types survive decoding; use
/// `kind` to switch on the known ones.
public struct FollowableActivity: Codable {
	public let activityType: String
	public let occurredAt: Date?
	public let album: Album?
	public let historyMix: FeedHistoryMix?

	private enum CodingKeys: String, CodingKey {
		case activityType, occurredAt, album, historyMix
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		activityType = try container.decode(String.self, forKey: .activityType)
		occurredAt = try? container.decodeIfPresent(Date.self, forKey: .occurredAt)
		// The shared `Album` model rejects the v2 payload's `streamStartDate`
		// (e.g. "2020-11-06T00:00:00Z"), so decode through the tolerant v2
		// album subset and convert.
		if let albumPayload = try? container.decodeIfPresent(HomeFeedAlbum.self, forKey: .album) {
			album = albumPayload.asAlbum
		} else {
			album = nil
		}
		historyMix = try? container.decodeIfPresent(FeedHistoryMix.self, forKey: .historyMix)
	}

	/// The known activity kinds, for switching in the UI.
	public var kind: FeedActivityKind {
		switch activityType {
		case "NEW_ALBUM_RELEASE":
			.newAlbumRelease
		case "NEW_HISTORY_MIX":
			.newHistoryMix
		default:
			.unknown
		}
	}
}

/// The known `FollowableActivity.activityType` values.
public enum FeedActivityKind: Equatable {
	case newAlbumRelease
	case newHistoryMix
	case unknown
}

/// The `historyMix` payload of a `NEW_HISTORY_MIX` activity.
///
/// The v2 activities payload does not match the v1 `MixesItem` shape: its
/// subtitle key is `subtitle` (not `subTitle`) and display text may live in
/// `titleTextInfo`/`subtitleTextInfo`, so `MixesItem` can't decode it. This is
/// a minimal, tolerant subset instead — only `id` is required, everything else
/// degrades to `nil` on a shape mismatch rather than failing the activity.
///
/// - Note: The exact shape could not be verified against a live
///   `NEW_HISTORY_MIX` activity; the fields follow the shape used by other
///   TIDAL clients (tonearm, plugin.audio.tidal2).
public struct FeedHistoryMix: Codable, Identifiable {
	public let id: String
	public let mixType: MixType?
	public let title: String?
	public let subtitle: String?
	public let titleTextInfo: HomeFeedTextInfo?
	public let subtitleTextInfo: HomeFeedTextInfo?
	public let images: MixesImages?
	public let detailImages: MixesImages?

	private enum CodingKeys: String, CodingKey {
		case id, mixType, title, subtitle, titleTextInfo, subtitleTextInfo, images, detailImages
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		mixType = try? container.decodeIfPresent(MixType.self, forKey: .mixType)
		title = try? container.decodeIfPresent(String.self, forKey: .title)
		subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
		titleTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .titleTextInfo)
		subtitleTextInfo = try? container.decodeIfPresent(HomeFeedTextInfo.self, forKey: .subtitleTextInfo)
		images = try? container.decodeIfPresent(MixesImages.self, forKey: .images)
		detailImages = try? container.decodeIfPresent(MixesImages.self, forKey: .detailImages)
	}

	/// Display title, preferring the plain `title` and falling back to `titleTextInfo.text`.
	public var displayTitle: String { title ?? titleTextInfo?.text ?? "" }
	/// Display subtitle, preferring the plain `subtitle` and falling back to `subtitleTextInfo.text`.
	public var displaySubtitle: String { subtitle ?? subtitleTextInfo?.text ?? "" }
}
