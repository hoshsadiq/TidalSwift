//
//  Others.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 19.03.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation

public enum AudioQuality: String, Codable {
	/// Kept so a Max subscriber can be offered Max, but know what Tidal actually returns:
	/// measured 2026-10-04, `HI_RES_LOSSLESS` and `LOSSLESS` answer with the same file
	/// (FLAC 44,1 kHz / 16 Bit, identical bit rate), because Tidal silently downgrades the
	/// request instead of refusing it. True 24 Bit is only reachable through the OpenAPI
	/// `trackManifests` route with FairPlay DRM, which this app does not implement, so a
	/// "Max" setting buys honesty about the subscription, not hi-res audio.
	case max = "HI_RES_LOSSLESS"
	case high = "LOSSLESS"			// Lossless, 16 Bit / 44,1 kHz
	case medium = "HIGH"			// 320 kbps
	case low = "LOW"				// 96 kbps

	/// Unknown values decode to `.high` instead of throwing. Throwing would fail the whole
	/// object, so a single unrecognised quality from Tidal would take an entire album,
	/// playlist or favourites list down with it.
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let rawValue = try container.decode(String.self)
		self = AudioQuality(rawValue: rawValue) ?? .high
	}
}

/// Tidal's per-track quality markers. `tags` carries strings such as `HIRES_LOSSLESS`,
/// which is how a track advertises a rendition the playback endpoints will not serve.
public struct MediaMetadata: Codable {
	public let tags: [String]
}

extension AudioQuality: CaseIterable {}
extension AudioQuality: Identifiable {
	public var id: Self { self }
}

extension AudioQuality {
	public var title: LocalizedStringResource {
		switch self {
		case .max: "Max (Lossless, 24 Bit, 192 kHz)"
		case .high: "High (16 Bit / 44,1 kHz)"
		case .medium: "Low (320 kbps)"
		case .low: "Low (32 kbps)"
		}
	}
}

struct LoginResponse: Decodable {
	let userId: Int
	let sessionId: String
	let countryCode: String
}
