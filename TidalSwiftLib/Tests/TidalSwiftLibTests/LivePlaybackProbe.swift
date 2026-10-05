//
//  LivePlaybackProbe.swift
//  TEMPORARY — delete after running. Not part of the suite.
//
//  Exercises the production resolver against live Tidal with a session passed in
//  through the environment, so no test ever reads the developer's stored session.
//  Skips when TIDAL_TEST_TOKEN is absent, which is why it is safe to leave in place
//  for a normal `swift test` run.
//

import AVFoundation
import XCTest
@testable import TidalSwiftLib

@MainActor
final class LivePlaybackProbe: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "LiveProbe")

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	private func liveSession() throws -> Session {
		guard let token = ProcessInfo.processInfo.environment["TIDAL_TEST_TOKEN"], !token.isEmpty else {
			throw XCTSkip("TIDAL_TEST_TOKEN is not set — live probe skipped")
		}
		return offlineLibrary.makeSession(config: Config(
			accessToken: token,
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: .max
		))
	}

	/// Hazlett, "fast like you": stereo *and* Atmos renditions. Built by hand so the
	/// probe does not need a fully signed-in session for the catalogue call.
	private func dualFormatTrack() -> Track {
		let id = 433_645_363
		return Track(
			id: id,
			title: "fast like you",
			duration: 224,
			replayGain: 0,
			peak: nil,
			allowStreaming: true,
			streamReady: true,
			streamStartDate: nil,
			premiumStreamingOnly: nil,
			trackNumber: 1,
			volumeNumber: 1,
			version: nil,
			popularity: 0,
			copyright: nil,
			description: nil,
			url: URL(string: "https://tidal.com/track/\(id)")!,
			isrc: nil,
			editable: false,
			explicit: false,
			audioQuality: .max,
			audioModes: [.stereo, .dolbyAtmos],
			artist: nil,
			artists: [],
			album: Album(
				id: 433_645_358,
				title: "last night you said you missed me",
				duration: nil,
				streamReady: nil,
				streamStartDate: nil,
				allowStreaming: nil,
				premiumStreamingOnly: nil,
				numberOfTracks: nil,
				numberOfVideos: nil,
				numberOfVolumes: nil,
				releaseDate: nil,
				copyright: nil,
				type: nil,
				version: nil,
				url: nil,
				cover: nil,
				videoCover: nil,
				explicit: false,
				upc: nil,
				popularity: nil,
				audioQuality: .high,
				audioModes: [.stereo],
				artist: nil,
				artists: nil
			),
			mixes: nil,
			dateAdded: nil,
			index: nil,
			itemUuid: nil,
			bpm: nil,
			key: nil,
			keyScale: nil
		)
	}

	func testTidalsRouteProducesADecryptedPlayableFileAtMax() async throws {
		let session = try liveSession()
		let track = dualFormatTrack()

		let start = Date()
		let playback = await HiResStreaming.playbackFile(for: track, session: session, quality: .max)
		let elapsed = Date().timeIntervalSince(start)
		let resolved = try XCTUnwrap(playback, "Tidal's route produced no file")

		let file = try AVAudioFile(forReading: resolved.url)
		let format = file.fileFormat
		let bits = resolved.bitDepth.map(String.init) ?? "unknown"
		print("[LIVE] Max: \(resolved.url.lastPathComponent) in \(String(format: "%.2f", elapsed))s — \(Int(format.sampleRate)) Hz, \(bits) bit, \(format.channelCount) ch, \(file.length) frames")

		XCTAssertEqual(Int(format.sampleRate), 44_100)
		XCTAssertEqual(resolved.bitDepth, 24)
		XCTAssertEqual(format.channelCount, 2)
		XCTAssertGreaterThan(file.length, 0)
	}

	func testTidalsRouteServesSixteenBitAtLossless() async throws {
		let session = try liveSession()
		let track = dualFormatTrack()

		let playback = await HiResStreaming.playbackFile(for: track, session: session, quality: .high)
		let resolved = try XCTUnwrap(playback, "Tidal's route produced no file at Lossless")
		let bits = resolved.bitDepth.map(String.init) ?? "unknown"
		let rate = resolved.sampleRate.map(String.init) ?? "unknown"
		print("[LIVE] Lossless: \(resolved.url.lastPathComponent) — \(rate) Hz, \(bits) bit")

		XCTAssertEqual(resolved.bitDepth, 16)
	}

	func testADashTierAssemblesPlayableAudio() async throws {
		let session = try liveSession()
		let track = dualFormatTrack()

		let start = Date()
		let playback = await DashAudio.playbackFile(for: track, session: session, preferredQuality: .medium)
		let elapsed = Date().timeIntervalSince(start)
		let resolved = try XCTUnwrap(playback, "the DASH route produced no file")

		let file = try AVAudioFile(forReading: resolved.url)
		print("[LIVE] High: \(resolved.url.lastPathComponent) in \(String(format: "%.2f", elapsed))s — \(Int(file.fileFormat.sampleRate)) Hz, \(file.fileFormat.channelCount) ch, \(file.length) frames")

		XCTAssertEqual(file.fileFormat.channelCount, 2)
		XCTAssertGreaterThan(file.length, 0)
	}
}
