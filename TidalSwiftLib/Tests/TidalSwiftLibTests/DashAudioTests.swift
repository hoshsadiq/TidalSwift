//
//  DashAudioTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins how a High/Low DASH manifest is read and assembled: Tidal refuses `streamUrl`
/// at those tiers and answers with an unencrypted AAC manifest split into fMP4 segments.
/// Counting the segments and concatenating them in order both have to be right — getting
/// either wrong produces a file that plays a few seconds and stops.
@MainActor
final class DashAudioTests: XCTestCase {

	// MARK: - MPD parsing

	private func fixture(_ name: String = "dashManifestHigh") throws -> Data {
		let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
		return try Data(contentsOf: url)
	}

	/// The fixture is a live High manifest with the token stripped; `r="55"` means 56
	/// segments, plus the trailing `<S>` without `r`.
	func testRealManifestShapeParsesToTheExpectedSource() throws {
		let manifest = try DashAudioManifest(mpd: fixture())

		XCTAssertEqual(manifest.initializationURL.absoluteString, "https://sp-ad-fa.audio.tidal.com/mediatracks/0.mp4")
		XCTAssertEqual(manifest.mediaTemplate, "https://sp-ad-fa.audio.tidal.com/mediatracks/$Number$.mp4")
		XCTAssertEqual(manifest.startNumber, 1)
		XCTAssertEqual(manifest.segmentCount, 57)
		XCTAssertEqual(manifest.timescale, 44100)
	}

	func testBase64ManifestDecodesLikeTheRawMPD() throws {
		let base64 = try fixture().base64EncodedString()
		XCTAssertEqual(try DashAudioManifest(base64Manifest: base64), try DashAudioManifest(mpd: fixture()))
	}

	/// `r="0"` is one segment, not zero — the repeat count is in addition to the `<S>` entry.
	func testSingleSegmentWithZeroRepeatCounts() throws {
		let manifest = try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate initialization="https://x/init.mp4" media="https://x/$Number$.mp4" startNumber="1">
		<SegmentTimeline><S d="1000" r="0"/></SegmentTimeline>
		</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
		""")
		XCTAssertEqual(manifest.segmentCount, 1)
	}

	func testSeveralTimelineEntriesSumTheirRepeats() throws {
		let manifest = try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate initialization="https://x/init.mp4" media="https://x/$Number$.mp4" startNumber="7">
		<SegmentTimeline><S d="1" r="0"/><S d="1" r="2"/><S d="1"/></SegmentTimeline>
		</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
		""")
		XCTAssertEqual(manifest.segmentCount, 1 + 3 + 1)
		XCTAssertEqual(manifest.startNumber, 7)
		XCTAssertEqual(manifest.mediaURL(forNumber: 7)?.absoluteString, "https://x/7.mp4")
		XCTAssertEqual(manifest.mediaURL(forNumber: 11)?.absoluteString, "https://x/11.mp4")
	}

	/// The MPD is the only place an insecure URL could enter.
	func testHTTPManifestURLsAreUpgradedToHTTPS() throws {
		let manifest = try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate initialization="http://x/init.mp4" media="http://x/$Number$.mp4" startNumber="1">
		<SegmentTimeline><S d="1"/></SegmentTimeline>
		</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
		""")
		XCTAssertEqual(manifest.initializationURL.absoluteString, "https://x/init.mp4")
		XCTAssertEqual(manifest.mediaURL(forNumber: 1)?.absoluteString, "https://x/1.mp4")
	}

	/// A malformed document is refused with a typed error; the parser must not return a
	/// zero-segment manifest.
	func testMalformedManifestIsRefused() {
		XCTAssertThrowsError(try DashAudioManifest(mpd: Data("<MPD><broken".utf8))) { error in
			XCTAssertEqual(error as? DashAudioError, .malformedManifest)
		}
	}

	func testMissingSegmentTimelineIsRefused() {
		XCTAssertThrowsError(try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate initialization="https://x/init.mp4" media="https://x/$Number$.mp4" startNumber="1"/>
		</Representation></AdaptationSet></Period></MPD>
		""")) { error in
			XCTAssertEqual(error as? DashAudioError, .missingSegmentTimeline)
		}
	}

	/// Without a `$Number$` placeholder the template cannot be expanded to segments.
	func testUnsupportedMediaTemplateIsRefused() {
		XCTAssertThrowsError(try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate initialization="https://x/init.mp4" media="https://x/whole.mp4" startNumber="1">
		<SegmentTimeline><S d="1" r="2"/></SegmentTimeline>
		</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
		""")) { error in
			XCTAssertEqual(error as? DashAudioError, .unsupportedSegmentTemplate)
		}
	}

	func testMissingInitializationIsRefused() {
		XCTAssertThrowsError(try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate media="https://x/$Number$.mp4" startNumber="1">
		<SegmentTimeline><S d="1"/></SegmentTimeline>
		</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
		""")) { error in
			XCTAssertEqual(error as? DashAudioError, .missingInitializationURL)
		}
	}

	func testDocumentWithoutSegmentTemplateIsRefused() {
		XCTAssertThrowsError(try parse("<MPD><Period><AdaptationSet contentType=\"audio\"/></Period></MPD>")) { error in
			XCTAssertEqual(error as? DashAudioError, .missingSegmentTemplate)
		}
	}

	private func parse(_ mpd: String) throws -> DashAudioManifest {
		try DashAudioManifest(mpd: Data(mpd.utf8))
	}

	// MARK: - Assembly

	/// Each piece is a distinct byte so a reordered assembly fails.
	func testAssemblyConcatenatesInitAndSegmentsInOrder() async throws {
		let cdn = try makeCDN(segments: ["AAAA", "BBB", "CC"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		let destination = cdn.directory.appendingPathComponent("assembled.m4a")
		try await DashAudio.assemble(cdn.manifest, to: destination)

		let expected = Data("INIT".utf8) + Data("AAAA".utf8) + Data("BBB".utf8) + Data("CC".utf8)
		XCTAssertEqual(try Data(contentsOf: destination), expected)
	}

	/// A partial AAC file is worse than a reported error.
	func testFailedSegmentLeavesNoOutputFile() async throws {
		let cdn = try makeCDN(segments: ["AAAA", "BBB"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }
		let manifest = DashAudioManifest(
			initializationURL: cdn.directory.appendingPathComponent("init.mp4"),
			mediaTemplate: cdn.directory.appendingPathComponent("seg-$Number$.mp4").absoluteString,
			startNumber: 1,
			segmentCount: 3,
			timescale: nil
		)

		let destination = cdn.directory.appendingPathComponent("broken.m4a")
		do {
			try await DashAudio.assemble(manifest, to: destination)
			XCTFail("assembling a manifest with a missing segment must fail")
		} catch {
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a failed assembly must leave no file")
	}

	func testSegmentFetchIsRetriedOnce() async throws {
		let cdn = try makeCDN(segments: ["AAAA", "BBB", "CC"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		let attempts = Counter()
		let destination = cdn.directory.appendingPathComponent("retried.m4a")
		try await DashAudio.assemble(cdn.manifest, to: destination) { url in
			let count = await attempts.increment(url)
			if count == 1, url.lastPathComponent == "seg-2.mp4" {
				throw DashAudio.fetchFailure(for: url)
			}
			return try Data(contentsOf: url)
		}
		let expected = Data("INIT".utf8) + Data("AAAA".utf8) + Data("BBB".utf8) + Data("CC".utf8)
		XCTAssertEqual(try Data(contentsOf: destination), expected)
	}

	/// A cancelled assembly must stop rather than spend its retries, and leave no file.
	/// The fetcher is held open until the test cancels, so a retry shows up as the same
	/// URL twice.
	func testCancelledAssemblyDoesNotRetryAndWritesNothing() async throws {
		let cdn = try makeCDN(segments: ["AAAA", "BBBB", "CCCC", "DDDD", "EEEE", "FFFF"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		let attempts = AttemptLog()
		let destination = cdn.directory.appendingPathComponent("cancelled.m4a")
		let assembly = Task {
			try await DashAudio.assemble(cdn.manifest, to: destination) { url in
				if url.lastPathComponent == "init.mp4" {
					return try Data(contentsOf: url)
				}
				await attempts.record(url)
				try await Task.sleep(for: .seconds(30))
				return Data()
			}
		}
		await attempts.awaitFirstAttempt()
		assembly.cancel()

		do {
			try await assembly.value
			XCTFail("a cancelled assembly must fail rather than write a file")
		} catch is CancellationError {
		}

		let attempted = await attempts.attempted
		XCTAssertEqual(attempted.count, Set(attempted).count, "a cancelled fetch must not be retried")
		XCTAssertLessThanOrEqual(attempted.count, DashAudio.maxConcurrentFetches, "cancellation must stop before the next batch starts")
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a cancelled assembly must leave no file")
	}

	/// A segment that never answers must fail on the timeout, not ride URLSession's
	/// per-attempt timeout through every retry.
	func testStalledSegmentTimesOutWithoutWritingAFile() async throws {
		let cdn = try makeCDN(segments: ["AAAA", "BBBB"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }
		let destination = cdn.directory.appendingPathComponent("stalled.m4a")

		do {
			try await DashAudio.assemble(cdn.manifest, to: destination, fetch: { _ in
				try await Task.sleep(for: .seconds(5))
				return Data()
			}, timeout: .milliseconds(50))
			XCTFail("a stalled segment must fail the assembly")
		} catch {
			XCTAssertEqual(error as? DashAudioError, .fetchFailed(host: "unknown"), "got \(error)")
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a timed-out assembly must leave no file")
	}

	/// A segment URL carries its own token, so the error names only the host.
	func testFetchFailureNamesOnlyTheHost() throws {
		let url = try XCTUnwrap(URL(string: "https://lgf.audio.tidal.com/mediatracks/secret/seg-1.mp4?token=secret"))
		let error = DashAudio.fetchFailure(for: url)

		XCTAssertEqual(error, .fetchFailed(host: "lgf.audio.tidal.com"))
		XCTAssertFalse(String(describing: error).contains("secret"))
	}

	private struct CDN: Sendable {
		let directory: URL
		let manifest: DashAudioManifest
	}

	private func makeCDN(segments: [String]) throws -> CDN {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("DashAudioTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data("INIT".utf8).write(to: directory.appendingPathComponent("init.mp4"))
		for (index, segment) in segments.enumerated() {
			try Data(segment.utf8).write(to: directory.appendingPathComponent("seg-\(index + 1).mp4"))
		}
		let manifest = DashAudioManifest(
			initializationURL: directory.appendingPathComponent("init.mp4"),
			mediaTemplate: directory.appendingPathComponent("seg-$Number$.mp4").absoluteString,
			startNumber: 1,
			segmentCount: segments.count,
			timescale: 44100
		)
		return CDN(directory: directory, manifest: manifest)
	}

	private actor Counter {
		private var counts: [String: Int] = [:]
		func increment(_ url: URL) -> Int {
			let key = url.absoluteString
			counts[key, default: 0] += 1
			return counts[key]!
		}
	}

	/// Lets the test wait until a fetch is genuinely in flight.
	private actor AttemptLog {
		private(set) var attempted: [String] = []
		private var waiter: CheckedContinuation<Void, Never>?

		func record(_ url: URL) {
			attempted.append(url.lastPathComponent)
			waiter?.resume()
			waiter = nil
		}

		func awaitFirstAttempt() async {
			guard attempted.isEmpty else { return }
			await withCheckedContinuation { waiter = $0 }
		}
	}

	// MARK: - Offline

	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "DashAudio")

	private var dashSeamCallCount = 0
	private var hiResSeamCallCount = 0
	override func setUp() {
		super.setUp()
		dashSeamCallCount = 0
		hiResSeamCallCount = 0
	}

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	/// The file is named with the quality marker, so the variant scheme recognises it as
	/// the wanted rendition.
	func testMediumOfflineWishStoresTheAssembledFileAndKeepsIt() async throws {
		let trackId = 644_000_001
		let session = makeSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline

		let cdn = try makeCDN(segments: ["AAAA", "BBB", "CC"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		// The direct stream is refused at this tier, so the sync falls through to the DASH
		// branch, which the second seam supplies.
		offline.resolveOfflineStream = { _ in nil }
		offline.resolveOfflineDashManifest = { [weak self] _ in
			self?.dashSeamCallCount += 1
			return cdn.manifest
		}
		offline.setOfflineTracksForTesting([makeStereoTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(try libraryFileNames(), ["\(trackId).high.m4a"])
		let stored = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library/\(trackId).high.m4a")
		let expected = Data("INIT".utf8) + Data("AAAA".utf8) + Data("BBB".utf8) + Data("CC".utf8)
		XCTAssertEqual(try Data(contentsOf: stored), expected)
		XCTAssertEqual(dashSeamCallCount, 1, "the first sync must assemble the track once")

		offline.setOfflineTracksForTesting([makeStereoTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(dashSeamCallCount, 1, "a second sync must not re-assemble the already-stored track")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).high.m4a"], "a second sync must neither re-download nor prune the file")
	}

	func testMediumAssembledFileIsRecognisedAsTheMediumVariant() async throws {
		let trackId = 644_000_002
		let session = makeSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline

		let cdn = try makeCDN(segments: ["AAAA"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }
		offline.resolveOfflineStream = { _ in nil }
		offline.resolveOfflineDashManifest = { _ in cdn.manifest }
		offline.setOfflineTracksForTesting([makeStereoTrack(id: trackId)])
		await offline.awaitOngoingSync()

		let stream = await offline.stream(for: makeStereoTrack(id: trackId))
		XCTAssertEqual(stream?.url.lastPathComponent, "\(trackId).high.m4a")
		XCTAssertEqual(stream?.pathExtension, "m4a")
		XCTAssertFalse(stream?.isDolbyAtmos ?? true)
	}

	/// The offline quality decides the route even on a session that can use the hi-res
	/// stereo route: at Medium the sync must assemble AAC, never take the FLAC branch.
	func testMediumOfflineWishOnACapableSessionStoresTheAssembledFile() async throws {
		let trackId = 644_000_003
		let session = makeCapableSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline

		let cdn = try makeCDN(segments: ["AAAA", "BBB"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		// If the hi-res branch were taken this seam would supply a FLAC, not the assembled AAC.
		offline.resolveHiResOfflineStream = { [weak self] _ in
			self?.hiResSeamCallCount += 1
			return AcceptedHiResManifest(url: cdn.directory.appendingPathComponent("init.mp4"), keyId: "unused")
		}
		offline.resolveOfflineStream = { _ in nil }
		offline.resolveOfflineDashManifest = { _ in cdn.manifest }
		offline.setOfflineTracksForTesting([makeStereoTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(hiResSeamCallCount, 0, "Medium must not take the FLAC route on a capable session")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).high.m4a"])
		let stored = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library/\(trackId).high.m4a")
		let expected = Data("INIT".utf8) + Data("AAAA".utf8) + Data("BBB".utf8)
		XCTAssertEqual(try Data(contentsOf: stored), expected)
	}

	// MARK: - Helpers

	private func makeSession(offlineAudioQuality: AudioQuality) -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: offlineAudioQuality
		))
	}

	/// A session whose token carries the `cuk` claim, so the hi-res route is available.
	private func makeCapableSession(offlineAudioQuality: AudioQuality) -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: Self.tokenWithCukClaim(),
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: offlineAudioQuality
		))
	}

	private static func tokenWithCukClaim() -> String {
		// base64url of `{"uid":1,"cuk":"client-key"}`, the payload the other hi-res tests build.
		let body = "eyJ1aWQiOjEsImN1ayI6ImNsaWVudC1rZXkifQ"
		return "Bearer .\(body).signature"
	}

	private func libraryFileNames() throws -> [String] {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	private func makeStereoTrack(id: Int) -> Track {
		let artist = Artist(
			id: 1, name: "Tester", artistTypes: nil, url: nil, picture: nil,
			popularity: nil, type: nil, banner: nil, relationType: nil
		)
		let album = Album(
			id: 2, title: "Test Album", duration: nil, streamReady: nil, streamStartDate: nil,
			allowStreaming: nil, premiumStreamingOnly: nil, numberOfTracks: nil, numberOfVideos: nil,
			numberOfVolumes: nil, releaseDate: nil, copyright: nil, type: nil, version: nil,
			url: nil, cover: nil, videoCover: nil, explicit: false, upc: nil, popularity: nil,
			audioQuality: nil, audioModes: [.stereo], artist: artist, artists: nil
		)
		return Track(
			id: id, title: "Test Track", duration: 1, replayGain: 0, peak: nil,
			allowStreaming: true, streamReady: true, streamStartDate: nil, premiumStreamingOnly: nil,
			trackNumber: 1, volumeNumber: 1, version: nil, popularity: 1, copyright: nil,
			description: nil, url: URL(string: "https://tidal.com/track/\(id)")!, isrc: nil,
			editable: false, explicit: false, audioQuality: .medium, audioModes: [.stereo],
			artist: artist, artists: [artist], album: album, mixes: nil, dateAdded: nil,
			index: nil, itemUuid: nil, bpm: nil, key: nil, keyScale: nil
		)
	}
}
