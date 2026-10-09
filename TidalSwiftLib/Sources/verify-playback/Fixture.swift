//
//  Fixture.swift
//  verify-playback
//
//  A hermetic stand-in for Tidal's manifest endpoint: a local HLS fixture fed through the
//  same resolve, assembly and decode path, with no network.
//

import Foundation
import TidalSwiftLib

enum Fixture {
	/// A track that advertises stereo and Atmos, so every rung of the ladder is in play.
	/// Decoded from JSON rather than built with the memberwise initialiser, which is internal
	/// to the library and this tool is a separate module; the JSON is the API's own shape.
	static func track(id: Int) -> Track? {
		let json = """
		{
		  "id": \(id),
		  "title": "Fixture Track",
		  "duration": 1,
		  "replayGain": 0,
		  "allowStreaming": true,
		  "streamReady": true,
		  "trackNumber": 1,
		  "volumeNumber": 1,
		  "popularity": 0,
		  "url": "https://tidal.com/track/\(id)",
		  "editable": false,
		  "explicit": false,
		  "audioQuality": "HI_RES_LOSSLESS",
		  "audioModes": ["STEREO", "DOLBY_ATMOS"],
		  "mediaMetadata": { "tags": ["HIRES_LOSSLESS"] },
		  "artists": [],
		  "album": { "id": 2, "title": "Fixture Album", "audioModes": ["STEREO", "DOLBY_ATMOS"] }
		}
		"""
		return try? JSONDecoder().decode(Track.self, from: Data(json.utf8))
	}

	/// Feeds one rung's playlist in place of the manifest request: every rung resolves to the
	/// same local multivariant playlist, so the resolve, assembly and decode path runs end to
	/// end with no network. The fixture offers both a stereo and an Atmos rendition and is
	/// marked hi-res, so the expectation table and the fixture agree and a hermetic run should
	/// read `match` throughout — the mismatches this tool looks for come from TIDAL, not here.
	static func resolver(multivariantURL: URL) -> (Int, HLSRung) async throws -> URL {
		{ _, _ in multivariantURL }
	}

	/// A fixture session needs the desktop `cuk` claim so the route policy reports the same
	/// route list a real run does. The token is unsigned and never leaves this process; only the
	/// claim's presence is read.
	static var desktopAccessToken: String {
		let payload = Data("{\"cuk\":\"fixture\"}".utf8)
			.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return "Bearer e30.\(payload).sig"
	}
}
