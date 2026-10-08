//
//  PlaybackManifestCeilingTests.swift
//  TidalSwiftLibTests
//

import Foundation
import XCTest
@testable import TidalSwiftLib

/// Answers the two endpoints a stream resolution touches: a refusal for `/streamUrl`, so the
/// ladder falls through to the manifest, and a fixed Atmos BTS body for
/// `/playbackinfopostpaywall`, the rendition Tidal returns at every quality. The ceiling the
/// call site forwards is then what decides the answer, not the endpoint.
class CeilingStubURLProtocol: URLProtocol {
	/// The codecs and label the Atmos body carries, so a test can drive a spelling variance of
	/// the same answer.
	nonisolated(unsafe) static var atmosCodecs: String? = "eac3"
	nonisolated(unsafe) static var atmosLabel = "DOLBY_ATMOS"
	/// Requests this stub answered. A test asserts it moved, which proves the call reached the
	/// injected `Session.requestSession` instead of falling through to the network before it
	/// ever reached the ceiling assertion.
	nonisolated(unsafe) static var hitCount = 0

	/// The BTS body Tidal returns for an Atmos track at any quality: an `EAC3` codec inside a
	/// base64 manifest.
	private static func atmosBody() throws -> Data {
		var manifest: [String: Any] = [
			"urls": ["https://stub.invalid/atmos.m4a"],
			"encryptionType": "NONE"
		]
		if let atmosCodecs { manifest["codecs"] = atmosCodecs }
		let encoded = try JSONSerialization.data(withJSONObject: manifest).base64EncodedString()
		let body: [String: Any] = [
			"audioMode": atmosLabel,
			"manifestMimeType": "application/vnd.tidal.bts",
			"manifest": encoded
		]
		return try JSONSerialization.data(withJSONObject: body)
	}

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		Self.hitCount += 1
		guard let url = request.url else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		let isManifest = url.path.hasSuffix("/playbackinfopostpaywall")
		guard let response = HTTPURLResponse(
			url: url,
			statusCode: isManifest ? 200 : 404,
			httpVersion: "HTTP/1.1",
			headerFields: nil
		) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		let body = isManifest ? (try? Self.atmosBody()) ?? Data() : Data("{}".utf8)
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

/// Pins the ceiling the two resolution call sites forward to `PlaybackManifestPolicy`: the
/// policy is tested on its own, but nothing exercised `bestAudioUrl` or `Track.audioStream`
/// passing the user's setting through, so either could drop it for `.max` and stay green.
///
/// The stub is installed as `Session.requestSession`, and several tests assert the hit counter
/// moved, so a call site that stopped going through the seam would hit the network and fail
/// here instead of silently resolving.
@MainActor
final class PlaybackManifestCeilingTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "PlaybackManifestCeiling")
	private let trackId = 981_563_900

	override func setUp() {
		super.setUp()
		CeilingStubURLProtocol.atmosCodecs = "eac3"
		CeilingStubURLProtocol.atmosLabel = "DOLBY_ATMOS"
	}

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	private func makeSession() -> Session {
		let session = offlineLibrary.makeSession()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [CeilingStubURLProtocol.self]
		session.requestSession = URLSession(configuration: configuration)
		return session
	}

	private func makeTrack(id: Int, audioModes: [AudioMode] = [.stereo, .dolbyAtmos]) -> Track {
		let artist = Artist(
			id: 1, name: "Tester", artistTypes: nil, url: nil, picture: nil,
			popularity: nil, type: nil, banner: nil, relationType: nil
		)
		let album = Album(
			id: 2, title: "Test Album", duration: nil, streamReady: nil, streamStartDate: nil,
			allowStreaming: nil, premiumStreamingOnly: nil, numberOfTracks: nil, numberOfVideos: nil,
			numberOfVolumes: nil, releaseDate: nil, copyright: nil, type: nil, version: nil,
			url: nil, cover: nil, videoCover: nil, explicit: false, upc: nil, popularity: nil,
			audioQuality: nil, audioModes: audioModes, artist: artist, artists: nil
		)
		return Track(
			id: id, title: "Test Track", duration: 1, replayGain: 0, peak: nil,
			allowStreaming: true, streamReady: true, streamStartDate: nil, premiumStreamingOnly: nil,
			trackNumber: 1, volumeNumber: 1, version: nil, popularity: 1, copyright: nil,
			description: nil, url: URL(string: "https://tidal.com/track/\(id)")!, isrc: nil,
			editable: false, explicit: false, audioQuality: .max, audioModes: audioModes,
			artist: artist, artists: [artist], album: album, mixes: nil, dateAdded: nil,
			index: nil, itemUuid: nil, bpm: nil, key: nil, keyScale: nil
		)
	}

	/// `bestAudioUrl` must hand the manifest policy the user's ceiling, so the Atmos answer the
	/// fallback returns at Low is refused rather than played. Reverting its `ceiling:` argument
	/// to `.max` makes the Atmos rendition resolve and this fail.
	func testBestAudioUrlRefusesAnAtmosAnswerAtALowCeiling() async {
		let before = CeilingStubURLProtocol.hitCount
		let resolved = await makeSession().bestAudioUrl(
			trackId: trackId,
			preferredQuality: .low,
			preferDolbyAtmos: false
		)
		XCTAssertGreaterThan(CeilingStubURLProtocol.hitCount, before, "the request must reach the injected session, not the network")
		XCTAssertNil(resolved, "a Low ceiling must not play the Atmos answer the fallback returns")
	}

	func testBestAudioUrlPlaysTheAtmosAnswerAtAHighCeiling() async {
		let resolved = await makeSession().bestAudioUrl(
			trackId: trackId,
			preferredQuality: .high,
			preferDolbyAtmos: false
		)
		XCTAssertEqual(resolved?.isDolbyAtmos, true, "a High ceiling admits the Atmos answer")
		XCTAssertEqual(resolved?.url.pathExtension, "m4a")
	}

	/// The offline/direct call site, `Track.audioStream`, forwards the ceiling the same way.
	func testAudioStreamRefusesAnAtmosAnswerAtALowCeiling() async {
		let before = CeilingStubURLProtocol.hitCount
		let stream = await makeTrack(id: trackId).audioStream(
			session: makeSession(),
			audioQuality: .low,
			preferDolbyAtmos: false
		)
		XCTAssertGreaterThan(CeilingStubURLProtocol.hitCount, before, "the request must reach the injected session, not the network")
		XCTAssertNil(stream, "a Low ceiling must skip a track whose only answer is Atmos")
	}

	func testAudioStreamPlaysTheAtmosAnswerAtAHighCeiling() async {
		let stream = await makeTrack(id: trackId).audioStream(
			session: makeSession(),
			audioQuality: .high,
			preferDolbyAtmos: false
		)
		XCTAssertEqual(stream?.isDolbyAtmos, true, "a High ceiling admits the Atmos answer")
	}

	/// The explicit immersive ask is gated on the ceiling too (`ContentUrls.swift`), so the
	/// preference cannot pull the ~768 kbps E-AC-3 rendition in below High. Dropping
	/// `preferredQuality.admitsDolbyAtmos` from that site makes the immersive request and fails
	/// this, with no other test moving.
	func testTheExplicitAtmosAskIsRefusedAtALowCeiling() async {
		let resolved = await makeSession().bestAudioUrl(
			trackId: trackId,
			preferredQuality: .low,
			preferDolbyAtmos: true
		)
		XCTAssertNil(resolved, "the Atmos preference must not override a Low ceiling")
	}

	func testTheExplicitAtmosAskPlaysAtAHighCeiling() async {
		let resolved = await makeSession().bestAudioUrl(
			trackId: trackId,
			preferredQuality: .high,
			preferDolbyAtmos: true
		)
		XCTAssertEqual(resolved?.isDolbyAtmos, true, "a High ceiling admits the explicit Atmos ask")
	}

	/// `Track.audioStream`, the offline/download call site, gates the explicit immersive ask the
	/// same way. Dropping `audioQuality.admitsDolbyAtmos` there makes an Atmos-only track resolve
	/// at Low and fails this.
	func testAudioStreamRefusesTheExplicitAtmosAskAtALowCeiling() async {
		let stream = await makeTrack(id: trackId, audioModes: [.dolbyAtmos]).audioStream(
			session: makeSession(),
			audioQuality: .low,
			preferDolbyAtmos: true
		)
		XCTAssertNil(stream, "an Atmos-only track must be skipped below High even with the preference on")
	}

	/// The explicit Atmos ask reads the codec the same way `PlaybackManifestPolicy.accept` does:
	/// a spelling other than the recorded `eac3` is still the Atmos rendition. Demanding the
	/// exact string would return nil here and silently disable the preference.
	func testTheExplicitAtmosAskAcceptsAnotherEac3Spelling() async {
		CeilingStubURLProtocol.atmosCodecs = "ec-3"
		let url = await makeSession().dolbyAtmosUrl(trackId: trackId)
		XCTAssertNotNil(url, "an E-AC-3 manifest under another spelling is still the Atmos rendition")
	}

	/// A recognisably stereo answer to the immersive request is not the Atmos rendition, so the
	/// caller keeps the stereo path.
	func testTheExplicitAtmosAskRefusesAStereoAnswer() async {
		CeilingStubURLProtocol.atmosCodecs = "flac"
		let url = await makeSession().dolbyAtmosUrl(trackId: trackId)
		XCTAssertNil(url, "a stereo codec is not the Atmos rendition")
	}

	/// The v2 path builds its own request, so it must also go through the injected session. A
	/// future change back to `URLSession.shared` makes this call the network and fails here.
	func testTheV2RequestGoesThroughTheInjectedSession() async {
		let before = CeilingStubURLProtocol.hitCount
		let probe: V2Probe? = try? await makeSession().v2Get(
			url: URL(string: "https://stub.invalid/v2/probe")!,
			parameters: [:]
		)
		XCTAssertGreaterThan(CeilingStubURLProtocol.hitCount, before, "v2Get must use the injected session")
		XCTAssertEqual(probe?.id, nil)
	}

	/// The HLS manifest request is the other request builder outside the seam; it must use the
	/// injected session too.
	func testTheHLSManifestRequestGoesThroughTheInjectedSession() async {
		let before = CeilingStubURLProtocol.hitCount
		_ = try? await makeSession().hlsManifestRequest(trackId: trackId, rung: .stereo(.high))
		XCTAssertGreaterThan(CeilingStubURLProtocol.hitCount, before, "hlsManifestRequest must use the injected session")
	}
}

/// The decoded shape of the v2 probe body; only that the request reached the stub is asserted.
private struct V2Probe: Decodable {
	let id: String?
}
