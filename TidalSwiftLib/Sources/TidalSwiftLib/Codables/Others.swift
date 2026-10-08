//
//  Others.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 19.03.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation

public enum AudioQuality: String, Codable {
	/// Kept so a Max subscriber can be offered Max. On the direct-stream endpoints
	/// (`streamUrl`, `playbackinfopostpaywall`) Tidal silently answers a
	/// `HI_RES_LOSSLESS` request with the lossless file, byte-identical, measured
	/// 2026-10-04. The desktop host's `playbackinfo` does serve 24 Bit for the same
	/// request, but only to a session it recognises as the desktop client, and it
	/// returns it AES-encrypted. See `HiResStreaming` for that route.
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

struct LoginResponse: Decodable {
	let userId: Int
	let sessionId: String
	let countryCode: String
}
