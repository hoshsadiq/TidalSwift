//
//  DashAudioTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins how a High/Low DASH manifest is read and assembled.
///
/// Tidal refuses `streamUrl` at those tiers and answers the desktop endpoint with
/// an `application/dash+xml` manifest: an unencrypted AAC representation split
/// into fMP4 segments. Reading it means counting the segments from the
/// `<SegmentTimeline>` and concatenating them in order; getting either wrong
/// produces a file that plays a few seconds and stops, so the refusals are as
/// important as the successes.
///
/// Parsing runs against a fixture of the measured manifest shape. Assembly runs
/// against `file://` segment files standing in for the CDN, so no network is
/// touched. The offline outcome runs against the temporary library root from
/// `TemporaryOfflineLibrary`.
@MainActor
final class DashAudioTests: XCTestCase {

	// MARK: - MPD parsing

	private func fixture(_ name: String = "dashManifestHigh") throws -> Data {
		let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
		return try Data(contentsOf: url)
	}

	/// Rule: the real manifest shape yields its initialization URL, media
	/// template, start number and — the point — the segment count. `r="55"` means
	/// 56 segments, and the trailing `<S>` without `r` adds one more. The fixture
	/// is a live High manifest with the token stripped, so its `Role` and
	/// `AudioChannelConfiguration` children are parsed past, not tripped over.
	func testRealManifestShapeParsesToTheExpectedSource() throws {
		let manifest = try DashAudioManifest(mpd: fixture())

		XCTAssertEqual(manifest.initializationURL.absoluteString, "https://sp-ad-fa.audio.tidal.com/mediatracks/0.mp4")
		XCTAssertEqual(manifest.mediaTemplate, "https://sp-ad-fa.audio.tidal.com/mediatracks/$Number$.mp4")
		XCTAssertEqual(manifest.startNumber, 1)
		XCTAssertEqual(manifest.segmentCount, 57)
		XCTAssertEqual(manifest.timescale, 44100)
	}

	/// Rule: the base64 body decodes to the same manifest the raw MPD does.
	func testBase64ManifestDecodesLikeTheRawMPD() throws {
		let base64 = try fixture().base64EncodedString()
		XCTAssertEqual(try DashAudioManifest(base64Manifest: base64), try DashAudioManifest(mpd: fixture()))
	}

	/// Rule: `r="0"` is one segment, not zero — the repeat count is in addition
	/// to the `<S>` entry itself.
	func testSingleSegmentWithZeroRepeatCounts() throws {
		let manifest = try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate initialization="https://x/init.mp4" media="https://x/$Number$.mp4" startNumber="1">
		<SegmentTimeline><S d="1000" r="0"/></SegmentTimeline>
		</SegmentTemplate></Representation></AdaptationSet></Period></MPD>
		""")
		XCTAssertEqual(manifest.segmentCount, 1)
	}

	/// Rule: several `<S>` entries sum their repeats, and `startNumber` is read
	/// independently of the count.
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

	/// Rule: a malformed document is refused with a typed error rather than a
	/// wrong count. The parser must not return a zero-segment manifest.
	func testMalformedManifestIsRefused() {
		XCTAssertThrowsError(try DashAudioManifest(mpd: Data("<MPD><broken".utf8))) { error in
			XCTAssertEqual(error as? DashAudioError, .malformedManifest)
		}
	}

	/// Rule: a `SegmentTemplate` without a `<SegmentTimeline>` has no countable
	/// segments and is refused.
	func testMissingSegmentTimelineIsRefused() {
		XCTAssertThrowsError(try parse("""
		<MPD><Period><AdaptationSet contentType="audio"><Representation>
		<SegmentTemplate initialization="https://x/init.mp4" media="https://x/$Number$.mp4" startNumber="1"/>
		</Representation></AdaptationSet></Period></MPD>
		""")) { error in
			XCTAssertEqual(error as? DashAudioError, .missingSegmentTimeline)
		}
	}

	/// Rule: a media template without a `$Number$` placeholder cannot be expanded
	/// to individual segments and is refused, not assembled into one broken file.
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

	/// Rule: a `SegmentTemplate` without an initialization URL cannot produce a
	/// playable file and is refused.
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

	/// Rule: a document with no `SegmentTemplate` at all is refused.
	func testDocumentWithoutSegmentTemplateIsRefused() {
		XCTAssertThrowsError(try parse("<MPD><Period><AdaptationSet contentType=\"audio\"/></Period></MPD>")) { error in
			XCTAssertEqual(error as? DashAudioError, .missingSegmentTemplate)
		}
	}

	private func parse(_ mpd: String) throws -> DashAudioManifest {
		try DashAudioManifest(mpd: Data(mpd.utf8))
	}

	// MARK: - Assembly

	/// Rule: the assembled file is the initialization followed by every segment,
	/// in order. Each piece is a distinct byte so a reordered assembly fails.
	func testAssemblyConcatenatesInitAndSegmentsInOrder() async throws {
		let cdn = try makeCDN(segments: ["AAAA", "BBB", "CC"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		let destination = cdn.directory.appendingPathComponent("assembled.m4a")
		try await DashAudio.assemble(cdn.manifest, to: destination)

		let expected = Data("INIT".utf8) + Data("AAAA".utf8) + Data("BBB".utf8) + Data("CC".utf8)
		XCTAssertEqual(try Data(contentsOf: destination), expected)
	}

	/// Rule: a failed segment fetch fails the whole assembly and leaves no output
	/// file behind. A partial AAC file is worse than a reported error.
	func testFailedSegmentLeavesNoOutputFile() async throws {
		let cdn = try makeCDN(segments: ["AAAA", "BBB"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }
		// A manifest three segments long, whose third segment is missing.
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
			// Expected.
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a failed assembly must leave no file")
	}

	/// Rule: a fetcher that fails once is retried, so a transient CDN failure does
	/// not lose the track.
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

	/// Rule: a failed fetch names the host, never the URL. A segment URL carries its
	/// own token, and the error value is printed wherever it travels.
	func testFetchFailureNamesOnlyTheHost() throws {
		let url = try XCTUnwrap(URL(string: "https://lgf.audio.tidal.com/mediatracks/secret/seg-1.mp4?token=secret"))
		let error = DashAudio.fetchFailure(for: url)

		XCTAssertEqual(error, .fetchFailed(host: "lgf.audio.tidal.com"))
		XCTAssertFalse(String(describing: error).contains("secret"))
	}

	private struct CDN {
		let directory: URL
		let manifest: DashAudioManifest
	}

	/// Writes `init.mp4` plus `seg-<n>.mp4` files into a temporary directory and
	/// returns a manifest pointing at them.
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

	// MARK: - Offline

	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "DashAudio")

	private var dashSeamCallCount = 0
	private var hiResSeamCallCount = 0
	private let defaultsKeys = [
		"OfflineDB:Tracks",
		"OfflineDB:TrackAddedDates",
		"OfflineDB:FavoriteTracks",
		"OfflineDB:Albums",
		"OfflineDB:AlbumTracks",
		"OfflineDB:Playlists",
		"OfflineDB:PlaylistTracks",
		"OfflineDB:StandaloneOfflineTracks",
		"SaveFavoritesOffline",
		"offlinePreferDolbyAtmos"
	]
	private var savedDefaults: [String: Any] = [:]

	override func setUp() {
		super.setUp()
		for key in defaultsKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
		for key in defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
		dashSeamCallCount = 0
		hiResSeamCallCount = 0
	}

	override func tearDown() {
		for key in defaultsKeys {
			if let value = savedDefaults[key] {
				UserDefaults.standard.set(value, forKey: key)
			} else {
				UserDefaults.standard.removeObject(forKey: key)
			}
		}
		savedDefaults = [:]
		offlineLibrary.remove()
		super.tearDown()
	}

	/// Rule: at Medium the sync stores the assembled file rather than nothing, and
	/// a second sync neither re-downloads nor prunes it. The file is named with the
	/// quality marker, so the existing variant scheme recognises it as the wanted
	/// rendition.
	func testMediumOfflineWishStoresTheAssembledFileAndKeepsIt() async throws {
		let trackId = 644_000_001
		let session = makeSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline

		let cdn = try makeCDN(segments: ["AAAA", "BBB", "CC"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		// The direct stream is refused at this tier, so the seam returns nil and the
		// sync falls through to the DASH branch, which the second seam supplies.
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

	/// Rule: the offline file accepts the tier's own marker, so `variant` reads
	/// round the quality the DASH source represents.
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

	/// Rule: the offline quality decides the route even on a session that can use the
	/// hi-res stereo route. At Medium the route is DASH, so the sync must assemble the
	/// AAC file and never take the FLAC branch — the earlier session had no `cuk`, so it
	/// could not catch a session that wrongly led with the FLAC route at every tier.
	func testMediumOfflineWishOnACapableSessionStoresTheAssembledFile() async throws {
		let trackId = 644_000_003
		let session = makeCapableSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline

		let cdn = try makeCDN(segments: ["AAAA", "BBB"])
		defer { try? FileManager.default.removeItem(at: cdn.directory) }

		// If the hi-res branch were taken, this seam would supply a FLAC and the stored
		// file would be the decrypted one rather than the assembled AAC.
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

	/// A session whose token carries the `cuk` claim, so `hasHiResStereoAccess` is true
	/// and the hi-res route is genuinely available to the policy.
	private func makeCapableSession(offlineAudioQuality: AudioQuality) -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: Self.tokenWithCukClaim(),
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: offlineAudioQuality
		))
	}

	private static func tokenWithCukClaim() -> String {
		// base64url of `{"uid":1,"cuk":"client-key"}`, the same payload the other
		// hi-res tests build, written out so nothing has to force-try the encoder.
		let body = "eyJ1aWQiOjEsImN1ayI6ImNsaWVudC1rZXkifQ"
		return "Bearer .\(body).signature"
	}

	private func libraryFileNames() throws -> [String] {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	/// A plain stereo track, the shape whose `streamUrl` is refused at High/Low.
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
