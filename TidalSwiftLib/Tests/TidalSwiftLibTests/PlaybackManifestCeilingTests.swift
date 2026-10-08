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
	/// The BTS body Tidal returns for an Atmos track at any quality: an `EAC3` codec inside a
	/// base64 manifest, labelled `DOLBY_ATMOS`.
	private static func atmosBody() throws -> Data {
		let manifest: [String: Any] = [
			"urls": ["https://stub.invalid/atmos.m4a"],
			"codecs": "eac3",
			"encryptionType": "NONE"
		]
		let encoded = try JSONSerialization.data(withJSONObject: manifest).base64EncodedString()
		let body: [String: Any] = [
			"audioMode": "DOLBY_ATMOS",
			"manifestMimeType": "application/vnd.tidal.bts",
			"manifest": encoded
		]
		return try JSONSerialization.data(withJSONObject: body)
	}

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
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
@MainActor
final class PlaybackManifestCeilingTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "PlaybackManifestCeiling")
	private let trackId = 981_563_900

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
		let resolved = await makeSession().bestAudioUrl(
			trackId: trackId,
			preferredQuality: .low,
			preferDolbyAtmos: false
		)
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
		let stream = await makeTrack(id: trackId).audioStream(
			session: makeSession(),
			audioQuality: .low,
			preferDolbyAtmos: false
		)
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
}
