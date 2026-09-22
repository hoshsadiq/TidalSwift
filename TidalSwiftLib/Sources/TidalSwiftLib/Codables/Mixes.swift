//
//  Mix.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation
import SwiftUI

struct Mixes: Decodable {
	let selfLink: URL?
	let id: String
	let title: String
	let rows: [MixesModules]
}

struct MixesModules: Decodable {
	let modules: [MixesModule]
}

struct MixesModule: Decodable {
	let id: String
	let width: Int
	let title: String
	let pagedList: MixesPagedList
}

struct MixesPagedList: Decodable {
	let limit: Int
	let offset: Int
	let totalNumberOfItems: Int
	let items: [MixesItem]
	let dataApiPath: String
}

public enum MixType: String, Codable {
	case header = "MIX_HEADER" // Because  of how Tidal structures its data
	case welcome = "WELCOME_MIX"
	case video = "VIDEO_DAILY_MIX"
	case audio = "DAILY_MIX"
	case discovery = "DISCOVERY_MIX"
	case newRelease = "NEW_RELEASE_MIX"
	case track = "TRACK_MIX"
	case artist = "ARTIST_MIX"
	case songwriter = "SONGWRITER_MIX"
	case producer = "PRODUCER_MIX"
	case historyAllTime = "HISTORY_ALLTIME_MIX"
	case historyMonthly = "HISTORY_MONTHLY_MIX"
	case historyYearly = "HISTORY_YEARLY_MIX"
	case unknown = "UNKNOWN"

	// Tidal adds new mix types over time; unknown values must not break decoding.
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let rawValue = try container.decode(String.self)
		self = MixType(rawValue: rawValue) ?? .unknown
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

public struct MixesItem: Codable, Equatable, Identifiable {
	public let id: String
	public let title: String
	public let subTitle: String
	public let graphic: MixesGraphic?
	public let images: MixesImages?
	public let mixType: MixType
	/// The API's title colour (`titleTextInfo.color`), drawn over the artwork by
	/// cards that opt into the overlay. Optional so previously saved caches
	/// still decode.
	public let titleColor: String?
	/// The API's subtitle colour (`subTitleTextInfo.color`). Optional for the
	/// same reason as `titleColor`.
	public let subtitleColor: String?

	public init(id: String, title: String, subTitle: String, graphic: MixesGraphic?, images: MixesImages?, mixType: MixType, titleColor: String? = nil, subtitleColor: String? = nil) {
		self.id = id
		self.title = title
		self.subTitle = subTitle
		self.graphic = graphic
		self.images = images
		self.mixType = mixType
		self.titleColor = titleColor
		self.subtitleColor = subtitleColor
	}

	public static func == (lhs: MixesItem, rhs: MixesItem) -> Bool {
		lhs.id == rhs.id
	}
}

public struct MixesImages: Codable {
	public let small: MixesImage?
	public let medium: MixesImage?
	public let large: MixesImage?

	enum CodingKeys: String, CodingKey {
		case small = "SMALL"
		case medium = "MEDIUM"
		case large = "LARGE"
	}
}

public struct MixesImage: Codable {
	public let url: URL
	public let width: Int?
	public let height: Int?
}

struct MixIdResponse: Decodable {
	let id: String
}

public enum MixesGraphicType: String, Codable {
	case squaresGrid = "SQUARES_GRID"
	case rectanglesGrid = "RECTANGLES_GRID"
}

public struct MixesGraphic: Codable {
	public let type: MixesGraphicType
	public let text: String
	public let images: [MixesGraphicImage]
}

public enum MixesGraphicImageType: String, Codable {
	case artist = "ARTIST"
}

public struct MixesGraphicImage: Codable {
	public let id: String
	public let vibrantColor: String
	public let type: MixesGraphicImageType

	public func getImageUrl(session: Session, resolution: Int) -> URL? {
		session.imageUrl(imageId: id, resolution: resolution)
	}
}

struct Mix: Decodable {
	let selfLink: URL?
	let id: String
	let title: String
	let rows: [MixModules]
	// Aufpassen, da unterschiedliche Modules
	// Das interessante, welche Tracks enthält, ist [1]
}

struct MixModules: Decodable {
	let modules: [MixModule]
}

enum MixPlaylistType: String, Decodable {
	case header = "MIX_HEADER" // Because  of how Tidal structures its data
	case audio = "TRACK_LIST"
	case video = "VIDEO_LIST"
}

struct MixModule: Decodable {
	let id: String
	let title: String
	let type: MixPlaylistType
	let pagedList: Tracks?
}
