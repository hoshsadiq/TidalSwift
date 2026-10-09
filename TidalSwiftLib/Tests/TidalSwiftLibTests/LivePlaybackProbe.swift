//
//  LivePlaybackProbe.swift
//  Live probe for Tidal's playback route. Part of the suite: every test skips unless
//  TIDAL_TEST_TOKEN is set, so a normal `mise run test-lib` run reports these as
//  skipped and makes no network call.
//
//  Safety: the session is passed in through the environment, so no test reads the
//  developer's stored session, and every downloaded file is written into a temporary
//  directory the test creates and removes. Nothing here reads or writes the offline
//  library, and nothing deletes from the real playback cache at
//  `~/Library/Caches/TidalSwift/stream/`.
//

import AVFoundation
import XCTest
@testable import TidalSwiftLib

/// A main-queue latency probe: a background thread hands a block to the main queue and measures
/// how long it waits before running — that wait is how long the main actor is blocked, and a gap
/// of seconds is the stall a user feels as a frozen window.
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

	/// A cache directory under the system temp directory, so the probe never touches the real
	/// playback cache at `~/Library/Caches/TidalSwift/stream/`.
	private func makeTemporaryCacheDirectory() throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("LiveProbe-cache-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	/// A track built by hand so a probe needs no catalogue call.
	private func probeTrack(id: Int, title: String, albumId: Int, albumTitle: String, audioModes: [AudioMode] = [.stereo, .dolbyAtmos]) -> Track {
		Track(
			id: id,
			title: title,
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
			audioModes: audioModes,
			artist: nil,
			artists: [],
			album: Album(
				id: albumId,
				title: albumTitle,
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

	/// The point of the freeze fix: downloading an HLS track must not hold the main actor while
	/// it fetches and concatenates the segments. The monitor's largest wait is the stall.
	func testDownloadingAnHLSTrackDoesNotStallTheMainActor() async throws {
		let session = try liveSession()
		let trackId = 98_156_344
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }
		let playlistURL = try await session.hlsPlaylistURL(trackId: trackId, audioQuality: .max)

		let monitor = MainQueueLatencyMonitor()
		monitor.start()
		try? await Task.sleep(for: .milliseconds(50))
		let start = Date()
		let destination = try await HLSStreaming.downloadToCache(
			playlistURL, forTrackId: trackId, rung: .stereo(.max), cacheDirectory: cacheDirectory,
			fetch: HLSStreaming.defaultFetch(userAgent: AuthInformation.tidalClientUserAgent)
		)
		let elapsed = Date().timeIntervalSince(start)
		monitor.stop()

		XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "the HLS route produced no file")
		print("[LIVE] hls download: \(String(format: "%.2f", elapsed))s wall, main-actor stall \(String(format: "%.3f", monitor.maxLatencySeconds))s")
		print("[LIVE] hls download gaps: \(monitor.sampleLog)")
		XCTAssertLessThan(monitor.maxLatencySeconds, 0.25, "downloading an HLS track must not block the main actor")
	}

	/// The HLS route end to end, against Tidal: resolve the Max manifest, download and
	/// concatenate the variant, then load the file with AVFoundation and assert it is
	/// playable FLAC. Track 98,156,344 is a measured 24-bit track.
	func testHLSManifestDownloadProducesPlayableFLACAtMax() async throws {
		let session = try liveSession()
		let trackId = 98_156_344
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }

		print("[PLAYBACK] hls probe: resolving the Max manifest for track \(trackId)")
		let playlistURL = try await session.hlsPlaylistURL(trackId: trackId, audioQuality: .max)
		print("[PLAYBACK] hls probe: playlist on \(playlistURL.host ?? "unknown host")")

		let start = Date()
		let destination = try await HLSStreaming.downloadToCache(
			playlistURL, forTrackId: trackId, rung: .stereo(.max), cacheDirectory: cacheDirectory,
			fetch: HLSStreaming.defaultFetch(userAgent: AuthInformation.tidalClientUserAgent)
		)
		let elapsed = Date().timeIntervalSince(start)
		let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
		print("[PLAYBACK] hls probe: wrote \(destination.lastPathComponent), \(size) bytes in \(String(format: "%.2f", elapsed))s")

		let asset = AVURLAsset(url: destination)
		let duration = try await asset.load(.duration)
		let audioTracks = try await asset.loadTracks(withMediaType: .audio)
		let audio = try XCTUnwrap(audioTracks.first, "the concatenated file has no audio track")
		let descriptions = try await audio.load(.formatDescriptions)
		let subtype = descriptions.first.flatMap { description -> String? in
			var code = CMFormatDescriptionGetMediaSubType(description).bigEndian
			return String(bytes: withUnsafeBytes(of: &code) { Data($0) }, encoding: .ascii)
		} ?? "unknown"
		print("[PLAYBACK] hls probe: duration \(String(format: "%.2f", CMTimeGetSeconds(duration)))s, audio codec \(subtype)")

		XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)
		XCTAssertEqual(audioTracks.count, 1)
		XCTAssertEqual(subtype, "flac")
	}

	/// Stage 2 end to end, against Tidal: AVPlayer plays the resolved playlist directly,
	/// the cache fills behind the play, and the next play reads the cached file without
	/// resolving the manifest again. Muted throughout; never sound.
	func testHLSPlaylistPlaysMutedAndTheCachedFileTakesOver() async throws {
		let session = try liveSession()
		let track = probeTrack(id: 98_156_344, title: "hls probe", albumId: 98_156_344, albumTitle: "hls probe")
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }

		let resolvedSource = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .max, cacheDirectory: cacheDirectory
		)
		let first = try XCTUnwrap(resolvedSource, "the HLS manifest produced no source")
		print("[PLAYBACK] hls: step 1 resolves \(first.url.host ?? "unknown host")")

		let advancedFromPlaylist = try await playMuted(first.url)
		print("[PLAYBACK] hls: step 1 playlist advanced to \(String(format: "%.1f", advancedFromPlaylist))s")
		XCTAssertGreaterThan(advancedFromPlaylist, 0, "the playlist must advance while playing")

		let cached = await first.backgroundDownload?.value
		print("[PLAYBACK] hls: step 2 cached \(cached?.lastPathComponent ?? "nothing")")
		let cachedFile = try XCTUnwrap(cached, "the background cache write produced no file")

		var resolvedAgain = false
		let secondSource = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .max, cacheDirectory: cacheDirectory,
			resolvePlaylist: { _, _ in
				resolvedAgain = true
				throw HLSStreamError.requestFailed
			}
		)
		let second = try XCTUnwrap(secondSource, "the cached file was not served")
		XCTAssertEqual(second.url, cachedFile)
		XCTAssertNil(second.backgroundDownload, "a cached play must not start another download")
		XCTAssertFalse(resolvedAgain, "a cached play must not resolve the manifest again")
		print("[PLAYBACK] hls: step 2 badge \(HLSStreaming.badge(for: .max, sampleRate: second.sampleRate))")

		let advancedFromFile = try await playMuted(second.url)
		print("[PLAYBACK] hls: step 2 cached file advanced to \(String(format: "%.1f", advancedFromFile))s")
		XCTAssertGreaterThan(advancedFromFile, 0, "the cached file must advance while playing")
	}

	/// The quality ladder against Tidal: track 1,228,498 is refused `FLAC_HIRES` (measured
	/// 2026-10-06, `CLIENT_NOT_ENTITLED`), so a play at Max must step down to the next tier
	/// and still play. The badge must report the tier actually served, never Max. Muted.
	func testMaxOnARefusedHiResTrackStepsDownAndStillPlays() async throws {
		let session = try liveSession()
		let track = probeTrack(id: 1_228_498, title: "ladder probe", albumId: 1_228_498, albumTitle: "ladder probe")
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }

		let sourceValue = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .max, cacheDirectory: cacheDirectory
		)
		let source = try XCTUnwrap(sourceValue, "every stereo tier was refused for 1228498")
		print("[LIVE] ladder: track 1228498 asked HI_RES_LOSSLESS and was served \(source.rung.format)")
		print("[LIVE] ladder: badge \(HLSStreaming.badge(for: source.rung, sampleRate: source.sampleRate))")

		let advanced = try await playMuted(source.url)
		print("[LIVE] ladder: playlist advanced to \(String(format: "%.1f", advanced))s")
		XCTAssertGreaterThan(advanced, 0, "the stepped-down tier must still play")
		XCTAssertNotEqual(
			HLSStreaming.badge(for: source.rung),
			HLSStreaming.badge(for: .max),
			"the badge must report the served tier, not Max"
		)
	}

	/// The regression this lane fixes: track 241,647,167 advertises DOLBY_ATMOS and no STEREO,
	/// and the v1 `streamUrl` route refuses it at every quality. It resolves through HLS and
	/// plays. Muted throughout.
	func testAnAtmosAdvertisedTrackPlaysThroughHLSAtMax() async throws {
		let session = try liveSession()
		let track = probeTrack(
			id: 241_647_167, title: "atmos probe", albumId: 241_647_167, albumTitle: "atmos probe",
			audioModes: [.dolbyAtmos]
		)
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }

		let sourceValue = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .max, cacheDirectory: cacheDirectory
		)
		let source = try XCTUnwrap(sourceValue, "track 241647167 must resolve through HLS")
		print("[LIVE] atmos: preference off served \(source.rung.format), badge \(HLSStreaming.badge(for: source.rung, sampleRate: source.sampleRate))")

		let advanced = try await playMuted(source.url)
		print("[LIVE] atmos: playlist advanced to \(String(format: "%.1f", advanced))s")
		XCTAssertGreaterThan(advanced, 0, "the resolved rung must advance while playing")

		let cached = await source.backgroundDownload?.value
		print("[LIVE] atmos: preference off cached \(cached?.lastPathComponent ?? "nothing")")
		XCTAssertNotNil(cached, "the served rung must reach the cache")
	}

	/// The same track with the Atmos preference on takes the Atmos rung, which is the whole
	/// meaning of the preference: it chooses between rungs, it never removes a route.
	func testAnAtmosAdvertisedTrackTakesTheAtmosRungWhenPreferred() async throws {
		let session = try liveSession()
		let track = probeTrack(
			id: 241_647_167, title: "atmos probe", albumId: 241_647_167, albumTitle: "atmos probe",
			audioModes: [.stereo, .dolbyAtmos]
		)
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }

		let sourceValue = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .max, preferDolbyAtmos: true, cacheDirectory: cacheDirectory
		)
		let source = try XCTUnwrap(sourceValue, "the Atmos rung must resolve for track 241647167")
		print("[LIVE] atmos: preference on served \(source.rung.format), badge \(HLSStreaming.badge(for: source.rung, sampleRate: source.sampleRate))")
		XCTAssertEqual(source.rung, .dolbyAtmos, "the preference must take the Atmos rung")

		let advanced = try await playMuted(source.url)
		print("[LIVE] atmos: playlist advanced to \(String(format: "%.1f", advanced))s")
		XCTAssertGreaterThan(advanced, 0, "the Atmos rung must advance while playing")

		let cachedValue = await source.backgroundDownload?.value
		let cached = try XCTUnwrap(cachedValue, "the Atmos rung must reach the cache")
		print("[LIVE] atmos: preference on cached \(cached.lastPathComponent)")
		XCTAssertEqual(cached.lastPathComponent, "241647167-DOLBY_ATMOS.m4a")

		// A second play reads the cached file with no resolve, which is the point of caching.
		var resolvedAgain = false
		let replayValue = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .max, preferDolbyAtmos: true, cacheDirectory: cacheDirectory,
			resolvePlaylist: { _, _ in
				resolvedAgain = true
				throw HLSStreamError.requestFailed
			}
		)
		let replay = try XCTUnwrap(replayValue, "the cached Atmos file must be served")
		XCTAssertEqual(replay.url, cached)
		XCTAssertFalse(resolvedAgain, "a cached play must not resolve the manifest again")
		let fromFile = try await playMuted(replay.url)
		print("[LIVE] atmos: second play from the cached file advanced to \(String(format: "%.1f", fromFile))s")
		XCTAssertGreaterThan(fromFile, 0, "the cached Atmos file must play")
	}

	/// The offline end state for an Atmos track: the sync downloads the E-AC-3 rendition into
	/// the temporary offline library, names it for the rendition, and serves that file.
	func testAnAtmosTrackDownloadsIntoTheOfflineLibrary() async throws {
		let session = try liveSession()
		let track = probeTrack(
			id: 241_647_167, title: "atmos offline probe", albumId: 241_647_167, albumTitle: "atmos offline probe",
			audioModes: [.dolbyAtmos]
		)
		let offline = session.helpers.offline
		offline.setPreferDolbyAtmos(to: true)
		offline.setOfflineTracksForTesting([track])
		await offline.awaitOngoingSync()

		let libraryDirectory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		let files = ((try? FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)) ?? []).sorted()
		print("[LIVE] atmos offline: library holds \(files)")
		XCTAssertEqual(files, ["241647167.atmos.m4a"], "the Atmos rendition must land under its marker")

		let streamValue = await offline.stream(for: track, ceiling: session.config.offlineAudioQuality)
		let stream = try XCTUnwrap(streamValue, "the stored Atmos file must be served offline")
		XCTAssertEqual(stream.url.lastPathComponent, "241647167.atmos.m4a")
		XCTAssertTrue(stream.isDolbyAtmos, "the stored file must be served as Atmos")
		let advanced = try await playMuted(stream.url)
		print("[LIVE] atmos offline: stored file advanced to \(String(format: "%.1f", advanced))s")
		XCTAssertGreaterThan(advanced, 0, "the stored Atmos file must play from disk")
	}

	/// The stereo entry for the same song still prefers stereo with the preference off: no
	/// Atmos rung is asked for a track that does not advertise it.
	func testTheStereoTrackPrefersStereoWithThePreferenceOff() async throws {
		let session = try liveSession()
		let track = probeTrack(
			id: 5_872_412, title: "stereo probe", albumId: 5_872_412, albumTitle: "stereo probe",
			audioModes: [.stereo]
		)
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }

		let sourceValue = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .max, cacheDirectory: cacheDirectory
		)
		let source = try XCTUnwrap(sourceValue, "track 5872412 must resolve through HLS")
		print("[LIVE] atmos: stereo entry served \(source.rung.format), badge \(HLSStreaming.badge(for: source.rung, sampleRate: source.sampleRate))")
		XCTAssertFalse(source.rung.isDolbyAtmos, "a stereo-only track must not take the Atmos rung")

		let advanced = try await playMuted(source.url)
		XCTAssertGreaterThan(advanced, 0, "the stereo rung must advance while playing")
	}

	/// A Low ceiling does not ask the Atmos rung, even with the preference on, so a 96 kbps setting
	/// never plays a ~768 kbps E-AC-3 stream (decided 2026-10-08). Track 241,647,167 offers Atmos; at
	/// Low the only rung is the stereo 96 kbps one. Muted.
	func testALowCeilingDoesNotPlayTheAtmosRungEvenWhenPreferred() async throws {
		let session = try liveSession()
		let track = probeTrack(
			id: 241_647_167, title: "atmos ceiling probe", albumId: 241_647_167, albumTitle: "atmos ceiling probe",
			audioModes: [.stereo, .dolbyAtmos]
		)
		let cacheDirectory = try makeTemporaryCacheDirectory()
		defer { try? FileManager.default.removeItem(at: cacheDirectory) }

		let sourceValue = await HLSStreaming.playbackSource(
			for: track, session: session, quality: .low, preferDolbyAtmos: true, cacheDirectory: cacheDirectory
		)
		let source = try XCTUnwrap(sourceValue, "track 241647167 must still resolve at a Low ceiling")
		print("[LIVE] atmos ceiling: at Low with the preference on served \(source.rung.format), badge \(HLSStreaming.badge(for: source.rung, sampleRate: source.sampleRate))")
		XCTAssertNotEqual(source.rung, .dolbyAtmos, "a Low ceiling must not play the Atmos rung")
		XCTAssertTrue(
			HLSStreaming.qualityLadder(for: .low).map(HLSRung.stereo).contains(source.rung),
			"the served rung must be on the Low ladder"
		)

		let advanced = try await playMuted(source.url)
		print("[LIVE] atmos ceiling: the stereo rung advanced to \(String(format: "%.1f", advanced))s")
		XCTAssertGreaterThan(advanced, 0, "the stereo rung must advance while playing")
	}

	/// A file below the ceiling is kept, so a second sync of an unchanged library makes no manifest
	/// request (decided 2026-10-08). Track 1,228,498 is refused `FLAC_HIRES`, so the first sync steps
	/// down to the lossless file; before this change the second sync re-resolved it.
	func testASecondOfflineSyncMakesNoManifestRequestForAnUnchangedLibrary() async throws {
		let session = try liveSession()
		let track = probeTrack(id: 1_228_498, title: "offline sync probe", albumId: 1_228_498, albumTitle: "offline sync probe")
		let offline = session.helpers.offline
		var resolves = 0
		offline.resolveOfflineHLSPlaylist = { _, rung in
			resolves += 1
			return try await session.hlsManifestRequest(trackId: track.id, rung: rung)
		}

		offline.setOfflineTracksForTesting([track])
		await offline.awaitOngoingSync()
		let afterFirst = resolves
		let libraryDirectory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		let files = ((try? FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)) ?? []).sorted()
		print("[LIVE] offline sync: first pass made \(afterFirst) manifest requests, files \(files)")
		XCTAssertGreaterThan(afterFirst, 0, "the first sync must resolve the track")

		offline.setOfflineTracksForTesting([track])
		await offline.awaitOngoingSync()
		print("[LIVE] offline sync: second pass made \(resolves - afterFirst) manifest requests")
		XCTAssertEqual(resolves, afterFirst, "a second sync of an unchanged library must make no manifest request")
	}

	/// Plays `url` muted until its position passes half a second, then stops. Returns the
	/// position reached, so a caller can assert the time advanced; the volume stays at
	/// zero, so this never makes sound.
	private func playMuted(_ url: URL, timeout: Double = 20) async throws -> Double {
		let player = AVPlayer(url: url)
		player.isMuted = true
		player.play()
		defer { player.pause() }
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			let seconds = CMTimeGetSeconds(player.currentTime())
			if seconds.isFinite, seconds > 0.5 { return seconds }
			try await Task.sleep(for: .milliseconds(250))
		}
		return CMTimeGetSeconds(player.currentTime())
	}
}
