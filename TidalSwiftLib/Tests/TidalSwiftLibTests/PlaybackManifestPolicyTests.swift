//
//  PlaybackManifestPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins how the manifest fallback reads a `/playbackinfopostpaywall` response:
/// which payloads are accepted, and — the point of the change — whether the
/// accepted rendition is reported as Dolby Atmos from the response's own
/// evidence rather than assumed from the caller.
@MainActor
final class PlaybackManifestPolicyTests: XCTestCase {
	/// A BTS payload, base64-encoded the way the API sends it. The URL is http
	/// on purpose, so the accept path is also pinned to upgrade it.
	private func btsPayload(codecs: String?, encryptionType: String? = "NONE", url: String = "http://lgf.audio.tidal.com/track.flac") -> String {
		var object: [String: Any] = ["urls": [url]]
		if let codecs { object["codecs"] = codecs }
		if let encryptionType { object["encryptionType"] = encryptionType }
		let data = try! JSONSerialization.data(withJSONObject: object)
		return data.base64EncodedString()
	}

	private func response(
		audioMode: AudioMode?,
		mimeType: String = "application/vnd.tidal.bts",
		manifest: String
	) -> TrackPlaybackInfo {
		TrackPlaybackInfo(audioMode: audioMode, manifestMimeType: mimeType, manifest: manifest)
	}

	/// Rule: an Atmos audioMode with an eac3 manifest is accepted and reported
	/// as Atmos, and the URL is upgraded to https.
	func testAtmosEac3ManifestIsReportedAsAtmos() {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .dolbyAtmos, manifest: btsPayload(codecs: "eac3"))
		)
		XCTAssertNotNil(accepted)
		XCTAssertTrue(accepted?.isDolbyAtmos ?? false)
		XCTAssertEqual(accepted?.url.scheme, "https")
	}

	/// Rule: a stereo audioMode is accepted (the URL is still chosen) but must
	/// NOT be reported as Atmos. This is the lie the policy exists to prevent.
	func testStereoManifestIsAcceptedButNotReportedAsAtmos() {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .stereo, manifest: btsPayload(codecs: "flac"))
		)
		XCTAssertNotNil(accepted)
		XCTAssertFalse(accepted?.isDolbyAtmos ?? true)
	}

	/// Rule: an Atmos audioMode on a manifest whose codec is not eac3 is still
	/// accepted, but the codec contradicts Atmos so it is not reported as Atmos.
	func testAtmosAudioModeWithNonEac3CodecIsNotReportedAsAtmos() {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .dolbyAtmos, manifest: btsPayload(codecs: "flac"))
		)
		XCTAssertNotNil(accepted)
		XCTAssertFalse(accepted?.isDolbyAtmos ?? true)
	}

	/// Rule: when the manifest carries no codec, the audioMode is the only
	/// evidence, so an Atmos audioMode is reported as Atmos.
	func testAtmosAudioModeWithoutCodecIsReportedAsAtmos() {
		let accepted = PlaybackManifestPolicy.accept(
			response(audioMode: .dolbyAtmos, manifest: btsPayload(codecs: nil))
		)
		XCTAssertNotNil(accepted)
		XCTAssertTrue(accepted?.isDolbyAtmos ?? false)
	}

	/// Rule: a DASH manifest is refused — AVPlayer cannot play it — so the
	/// ladder keeps looking. Nothing is reported.
	func testDashManifestIsRefused() {
		XCTAssertNil(
			PlaybackManifestPolicy.accept(
				response(audioMode: nil, mimeType: "application/dash+xml", manifest: btsPayload(codecs: "flac"))
			)
		)
	}

	/// Rule: an encrypted manifest is refused, whichever encryption type is used.
	func testEncryptedManifestIsRefused() {
		for encryption in ["AES128", "CENC", "cbcs"] {
			XCTAssertNil(
				PlaybackManifestPolicy.accept(
					response(audioMode: .dolbyAtmos, manifest: btsPayload(codecs: "eac3", encryptionType: encryption))
				),
				"\(encryption) must be refused"
			)
		}
	}

	/// Rule: a manifest that is not usable base64 or carries no URL is refused.
	func testMalformedManifestIsRefused() {
		XCTAssertNil(
			PlaybackManifestPolicy.accept(response(audioMode: .stereo, manifest: "not base64 !!"))
		)
		let noUrl = try! JSONSerialization.data(withJSONObject: ["codecs": "flac"]).base64EncodedString()
		XCTAssertNil(
			PlaybackManifestPolicy.accept(response(audioMode: .stereo, manifest: noUrl))
		)
	}
}
