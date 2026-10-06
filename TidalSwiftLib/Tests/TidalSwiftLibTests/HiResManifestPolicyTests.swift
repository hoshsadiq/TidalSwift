//
//  HiResManifestPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins how the desktop `playbackinfo` response is read: only a stereo BTS FLAC
/// manifest encrypted with `OLD_AES` is accepted. Mirrors `PlaybackManifestPolicyTests`,
/// because a payload that slips through here becomes a download of unplayable bytes.
@MainActor
final class HiResManifestPolicyTests: XCTestCase {
	private func btsPayload(
		codecs: String?,
		encryptionType: String?,
		keyId: String? = "a2V5",
		url: String = "http://lgf.audio.tidal.com/track.flac"
	) throws -> String {
		var object: [String: Any] = ["urls": [url]]
		if let codecs { object["codecs"] = codecs }
		if let encryptionType { object["encryptionType"] = encryptionType }
		if let keyId { object["keyId"] = keyId }
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

	/// Rule: a stereo, `OLD_AES`, FLAC BTS manifest is accepted, keeps its key and
	/// the URL is upgraded to https.
	func testStereoOldAesFlacManifestIsAccepted() throws {
		let accepted = HiResManifestPolicy.accept(
			response(audioMode: .stereo, manifest: try btsPayload(codecs: "flac", encryptionType: "OLD_AES"))
		)
		XCTAssertNotNil(accepted)
		XCTAssertEqual(accepted?.keyId, "a2V5")
		XCTAssertEqual(accepted?.url.scheme, "https")
	}

	/// Rule: a DASH body is refused — AVPlayer cannot play it and there is nothing to
	/// decrypt — so the caller keeps today's path.
	func testDashBodyIsRefused() throws {
		XCTAssertNil(
			HiResManifestPolicy.accept(
				response(audioMode: .stereo, mimeType: "application/dash+xml", manifest: try btsPayload(codecs: "flac", encryptionType: "OLD_AES"))
			)
		)
	}

	/// Rule: an Atmos rendition is refused, so a session without `cuk` (which Tidal
	/// answers with Atmos here) falls back instead of trying to decrypt E-AC-3.
	func testAtmosAudioModeIsRefused() throws {
		XCTAssertNil(
			HiResManifestPolicy.accept(
				response(audioMode: .dolbyAtmos, manifest: try btsPayload(codecs: "eac3", encryptionType: "OLD_AES"))
			)
		)
	}

	/// Rule: an encryption scheme this app cannot unwrap is refused, so its bytes are
	/// never downloaded as if they were playable.
	func testEncryptedWithSomethingElseIsRefused() throws {
		for encryption in ["CENC", "AES128", "cbcs"] {
			XCTAssertNil(
				HiResManifestPolicy.accept(
					response(audioMode: .stereo, manifest: try btsPayload(codecs: "flac", encryptionType: encryption))
				),
				"\(encryption) must be refused"
			)
		}
	}

	/// Rule: a manifest that is not usable base64, has the wrong codec, or carries no
	/// key or URL is refused.
	func testMalformedManifestIsRefused() throws {
		XCTAssertNil(
			HiResManifestPolicy.accept(response(audioMode: .stereo, manifest: "not base64 !!"))
		)
		XCTAssertNil(
			HiResManifestPolicy.accept(
				response(audioMode: .stereo, manifest: try btsPayload(codecs: "aac", encryptionType: "OLD_AES"))
			)
		)
		XCTAssertNil(
			HiResManifestPolicy.accept(
				response(audioMode: .stereo, manifest: try btsPayload(codecs: "flac", encryptionType: "OLD_AES", keyId: nil))
			)
		)
		let noUrl = try JSONSerialization.data(withJSONObject: ["codecs": "flac", "encryptionType": "OLD_AES", "keyId": "a2V5"]).base64EncodedString()
		XCTAssertNil(
			HiResManifestPolicy.accept(response(audioMode: .stereo, manifest: noUrl))
		)
	}
}
