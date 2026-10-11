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
	/// A track that advertises stereo and Atmos and is marked hi-res by default, so every rung of
	/// the ladder is in play. The three default ids name the three kinds the rules turn on (a
	/// hi-res stereo track, a plain stereo track, and one TIDAL advertises as Atmos with no
	/// stereo), so a bare fixture run exercises each branch of `servedRendition` instead of one
	/// track three times. Decoded from JSON rather than built with the memberwise initialiser,
	/// which is internal to the library and this tool is a separate module; the JSON is the API's
	/// own shape.
	static func track(id: Int) -> Track? {
		let audioModes: String
		let tags: String
		switch id {
		case 98_156_344:
			audioModes = #"["STEREO"]"#
			tags = #"["HIRES_LOSSLESS"]"#
		case 1_228_498:
			audioModes = #"["STEREO"]"#
			tags = "[]"
		case 241_647_167:
			audioModes = #"["DOLBY_ATMOS"]"#
			tags = "[]"
		default:
			audioModes = #"["STEREO", "DOLBY_ATMOS"]"#
			tags = #"["HIRES_LOSSLESS"]"#
		}
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
		  "audioModes": \(audioModes),
		  "mediaMetadata": { "tags": \(tags) },
		  "artists": [],
		  "album": { "id": 2, "title": "Fixture Album", "audioModes": \(audioModes) }
		}
		"""
		return try? JSONDecoder().decode(Track.self, from: Data(json.utf8))
	}

	/// Feeds one rung's playlist in place of the manifest request: every rung resolves to the
	/// same local multivariant playlist, so the resolve, assembly and decode path runs end to
	/// end with no network. The fixture holds one rendition, so a hermetic run matches only the
	/// rows whose rules expect that rendition's bytes and flags the rest; the mismatches this
	/// tool looks for come from TIDAL, not here. The seam cannot refuse a rung, so a TIDAL
	/// refusal still needs a live run.
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
