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

/// A main-queue latency probe: a background thread repeatedly hands a block to the
/// main queue and measures how long it waits before the block runs. That wait is how
/// long the main queue — and so the main actor — is blocked. A gap of seconds is the
/// stall a user feels as a frozen window.
final class MainQueueLatencyMonitor: @unchecked Sendable {
	private let lock = NSLock()
	private var running = false
	private var maxLatency: TimeInterval = 0
	private var startedAt = DispatchTime.now().uptimeNanoseconds
	private(set) var samples: [(String, Double)] = []

	var maxLatencySeconds: Double {
		lock.lock(); defer { lock.unlock() }
		return maxLatency
	}

	func start() {
		lock.lock()
		running = true
		maxLatency = 0
		samples = []
		startedAt = DispatchTime.now().uptimeNanoseconds
		lock.unlock()
		DispatchQueue.global(qos: .userInteractive).async { [self] in
			while true {
				lock.lock(); let keepGoing = running; lock.unlock()
				if !keepGoing { return }
				let sent = DispatchTime.now().uptimeNanoseconds
				let semaphore = DispatchSemaphore(value: 0)
				DispatchQueue.main.async {
					let latency = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e9
					self.lock.lock()
					if latency > self.maxLatency { self.maxLatency = latency }
					let at = Double(sent - self.startedAt) / 1e9
					if latency > 0.05 { self.samples.append((String(format: "%.3f", at), latency)) }
					self.lock.unlock()
					semaphore.signal()
				}
				_ = semaphore.wait(timeout: .now() + 2)
				Thread.sleep(forTimeInterval: 0.005)
			}
		}
	}

	func stop() {
		lock.lock(); running = false; lock.unlock()
	}

	var sampleLog: String {
		lock.lock(); defer { lock.unlock() }
		return samples.map { "\($0.0)s:+\(String(format: "%.3f", $0.1))s" }.joined(separator: " ")
	}
}

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

	/// The point of the freeze fix: preparing a hi-res track must not hold the main
	/// actor while it downloads and decrypts. The monitor's largest wait is the stall;
	/// before the fix it was the ~2.8 s decrypt of a ~30 MB file.
	func testPreparingAHiResTrackDoesNotStallTheMainActor() async throws {
		let session = try liveSession()
		let track = dualFormatTrack()
		let cacheDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LiveProbe-cache-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }
		try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

		let monitor = MainQueueLatencyMonitor()
		monitor.start()
		// Let the heartbeat settle before the measured call.
		try? await Task.sleep(for: .milliseconds(50))
		let start = Date()
		let url = await HiResStreaming.prepareFile(
			for: track, session: session, quality: .max, cacheDirectory: cacheDirectory
		)
		let elapsed = Date().timeIntervalSince(start)
		monitor.stop()

		XCTAssertNotNil(url, "Tidal's route produced no file")
		print("[LIVE] hi-res prepare: \(String(format: "%.2f", elapsed))s wall, main-actor stall \(String(format: "%.3f", monitor.maxLatencySeconds))s")
		print("[LIVE] hi-res prepare gaps: \(monitor.sampleLog)")
		XCTAssertLessThan(monitor.maxLatencySeconds, 0.25, "preparing a hi-res track must not block the main actor")
	}

	/// The same measurement for the DASH path. Its assembly was already off the main
	/// actor (the fetches run in a task group and the nonisolated helpers do no UI
	/// work), so this passes before and after the fix and pins that it stays that way.
	func testAssemblingADashTrackDoesNotStallTheMainActor() async throws {
		let session = try liveSession()
		let track = dualFormatTrack()
		// Force the assembly path: a cached file would return instantly and prove nothing.
		try? FileManager.default.removeItem(at: HiResStreamCache.dashFileURL(forTrackId: track.id, quality: .medium))

		let monitor = MainQueueLatencyMonitor()
		monitor.start()
		try? await Task.sleep(for: .milliseconds(50))
		let start = Date()
		let playback = await DashAudio.playbackFile(for: track, session: session, preferredQuality: .medium)
		let elapsed = Date().timeIntervalSince(start)
		monitor.stop()

		XCTAssertNotNil(playback, "the DASH route produced no file")
		print("[LIVE] dash assemble: \(String(format: "%.2f", elapsed))s wall, main-actor stall \(String(format: "%.3f", monitor.maxLatencySeconds))s")
		XCTAssertLessThan(monitor.maxLatencySeconds, 0.25, "assembling a DASH track must not block the main actor")
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
