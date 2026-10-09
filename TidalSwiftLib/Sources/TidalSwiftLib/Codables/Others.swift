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
	/// 2026-10-04. The desktop client's HLS manifest does serve a true 24-bit FLAC
	/// variant for the same request; see `HLSStreaming`.
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
	/// Whether a ceiling at this tier admits the Dolby Atmos rendition.
	///
	/// Atmos is a ~768 kbps E-AC-3 stream with no lower variant, so only a High or Max ceiling
	/// asks for it. A Medium or Low ceiling walks the stereo ladder alone rather than override a
	/// data-quality cap with a much larger stream (decided 2026-10-08). One place states the rule,
	/// so the HLS rung builder and the offline sync cannot drift apart on it.
	public nonisolated var admitsDolbyAtmos: Bool {
		self == .high || self == .max
	}
}

struct LoginResponse: Decodable {
	let userId: Int
	let sessionId: String
	let countryCode: String
}
