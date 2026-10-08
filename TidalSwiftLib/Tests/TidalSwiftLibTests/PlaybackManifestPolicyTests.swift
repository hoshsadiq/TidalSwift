//
//  PlaybackManifestPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins how the manifest fallback reads a `/playbackinfopostpaywall` response, and whether
/// the accepted rendition is reported as Dolby Atmos from the response's own evidence.
@MainActor
final class PlaybackManifestPolicyTests: XCTestCase {
	/// A BTS payload, base64-encoded the way the API sends it. The URL is http
	/// on purpose, so the accept path is also pinned to upgrade it.
	private func btsPayload(codecs: String?, encryptionType: String? = "NONE", url: String = "http://lgf.audio.tidal.com/track.flac") throws -> String {
		var object: [String: Any] = ["urls": [url]]
		if let codecs { object["codecs"] = codecs }
		if let encryptionType { object["encryptionType"] = encryptionType }
		let data = try JSONSerialization.data(withJSONObject: object)
		return data.base64EncodedString()
	}

	private func response(
		audioMode: AudioMode?,
		mimeType: String = "application/vnd.tidal.bts",
		manifest: String
	) -> TrackPlaybackInfo {
		TrackPlaybackInfo(audioMode: audioMode, manifestMimeType: mimeType, manifest: manifest)
	}

	func testAtmosEac3ManifestIsReportedAsAtmos() throws {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .dolbyAtmos, manifest: try btsPayload(codecs: "eac3")),
			ceiling: .max
		)
		XCTAssertNotNil(accepted)
		XCTAssertTrue(accepted?.isDolbyAtmos ?? false)
		XCTAssertEqual(accepted?.url.scheme, "https")
	}

	/// Accepted, but not reported as Atmos. This is the lie the policy exists to prevent.
	func testStereoManifestIsAcceptedButNotReportedAsAtmos() throws {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .stereo, manifest: try btsPayload(codecs: "flac")),
			ceiling: .max
		)
		XCTAssertNotNil(accepted)
		XCTAssertFalse(accepted?.isDolbyAtmos ?? true)
	}

	func testAtmosAudioModeWithNonEac3CodecIsNotReportedAsAtmos() throws {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .dolbyAtmos, manifest: try btsPayload(codecs: "flac")),
			ceiling: .max
		)
		XCTAssertNotNil(accepted)
		XCTAssertFalse(accepted?.isDolbyAtmos ?? true)
	}

	func testAtmosAudioModeWithoutCodecIsReportedAsAtmos() throws {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .dolbyAtmos, manifest: try btsPayload(codecs: nil)),
			ceiling: .max
		)
		XCTAssertNotNil(accepted)
		XCTAssertTrue(accepted?.isDolbyAtmos ?? false)
	}

	/// The ceiling gates what arrives, not only what is asked: Tidal answers the postpaywall
	/// endpoint with an Atmos rendition at any quality, so an Atmos answer below High is
	/// refused rather than accepted. A track with no other rendition is then skipped.
	func testAtmosAnswerIsRefusedAtACeilingThatDoesNotAdmitIt() throws {
		let atmos = response(audioMode: .dolbyAtmos, manifest: try btsPayload(codecs: "eac3"))
		XCTAssertNil(PlaybackManifestPolicy.accept(atmos, ceiling: .low), "a Low ceiling must refuse an Atmos answer")
		XCTAssertNil(PlaybackManifestPolicy.accept(atmos, ceiling: .medium), "a Medium ceiling must refuse an Atmos answer")
	}

	/// The other direction: at a ceiling that admits Atmos, the same answer is accepted and
	/// labelled, so the gate does not over-refuse.
	func testAtmosAnswerIsAcceptedAtHighAndMax() throws {
		let atmos = response(audioMode: .dolbyAtmos, manifest: try btsPayload(codecs: "eac3"))
		for ceiling in [AudioQuality.high, .max] {
			let accepted = PlaybackManifestPolicy.accept(atmos, ceiling: ceiling)
			XCTAssertNotNil(accepted, "a \(ceiling.rawValue) ceiling must accept an Atmos answer")
			XCTAssertTrue(accepted?.isDolbyAtmos ?? false)
		}
	}

	/// A stereo answer is a stereo answer at every ceiling: only an Atmos rendition is gated.
	func testStereoAnswerIsAcceptedAtEveryCeiling() throws {
		let stereo = response(audioMode: .stereo, manifest: try btsPayload(codecs: "flac"))
		for ceiling in AudioQuality.allCases {
			XCTAssertNotNil(
				PlaybackManifestPolicy.accept(stereo, ceiling: ceiling),
				"a \(ceiling.rawValue) ceiling must not refuse a stereo answer"
			)
		}
	}

	/// AVPlayer cannot play a DASH manifest, so the ladder keeps looking.
	func testDashManifestIsRefused() throws {
		XCTAssertNil(
			PlaybackManifestPolicy.accept(
				response(audioMode: nil, mimeType: "application/dash+xml", manifest: try btsPayload(codecs: "flac")),
				ceiling: .max
			)
		)
	}

	func testEncryptedManifestIsRefused() throws {
		for encryption in ["AES128", "CENC", "cbcs"] {
			XCTAssertNil(
				PlaybackManifestPolicy.accept(
					response(audioMode: .dolbyAtmos, manifest: try btsPayload(codecs: "eac3", encryptionType: encryption)),
					ceiling: .max
				),
				"\(encryption) must be refused"
			)
		}
	}

	func testMalformedManifestIsRefused() throws {
		XCTAssertNil(
			PlaybackManifestPolicy.accept(response(audioMode: .stereo, manifest: "not base64 !!"), ceiling: .max)
		)
		let noUrl = try JSONSerialization.data(withJSONObject: ["codecs": "flac"]).base64EncodedString()
		XCTAssertNil(
			PlaybackManifestPolicy.accept(response(audioMode: .stereo, manifest: noUrl), ceiling: .max)
		)
	}
}
