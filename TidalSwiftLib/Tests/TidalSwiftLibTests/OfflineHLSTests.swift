//
//  OfflineHLSTests.swift
//  TidalSwiftLibTests
//

import AVFoundation
import XCTest
@testable import TidalSwiftLib

/// A track the sync downloads through the HLS route ends up on disk as one playable file, and
/// the next sync recognises it rather than downloading it again.
@MainActor
final class OfflineHLSTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineHLS")

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	func testSyncWritesAPlayableHLSFileAndRecognisesItNextTime() async throws {
		let trackId = 779_000_001
		let libraryDirectory = try makeLibraryDirectory()
		let playlist = try makeLocalPlaylist(in: offlineLibrary.root)

		let session = try makeSession()
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		let downloads = Counter()
		offline.resolveOfflineHLSPlaylist = { _, _ in
			downloads.value += 1
			return playlist
		}

		await offline.awaitOngoingSync()

		let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
		XCTAssertEqual(files, ["\(trackId).lossless.m4a"], "the sync must store one assembled HLS file")

		let fileURL = libraryDirectory.appendingPathComponent("\(trackId).lossless.m4a")
		let original = try AVAudioFile(forReading: try silentM4AFixture())
		let stored = try AVAudioFile(forReading: fileURL)
		XCTAssertEqual(stored.length, original.length, "the stored file must decode as the source audio")
		XCTAssertEqual(stored.fileFormat.sampleRate, original.fileFormat.sampleRate)

		// The assembled file satisfies the wanted variant, so the next sync keeps it.
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(downloads.value, 1, "the assembled file must be recognised, not re-downloaded")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).lossless.m4a"])
	}

	func testAnOfflineTrackPlaysFromItsStoredFile() async throws {
		let trackId = 779_000_003
		let playlist = try makeLocalPlaylist(in: offlineLibrary.root)
		_ = try makeLibraryDirectory()

		let session = try makeSession()
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		offline.resolveOfflineHLSPlaylist = { _, _ in playlist }

		await offline.awaitOngoingSync()

		let streamValue = await offline.stream(for: makeTrack(id: trackId))
		let stream = try XCTUnwrap(streamValue, "the stored file must be served offline")
		XCTAssertEqual(stream.url.lastPathComponent, "\(trackId).lossless.m4a")
		XCTAssertFalse(stream.isDolbyAtmos)
		XCTAssertTrue(FileManager.default.fileExists(atPath: stream.url.path))
	}

	/// A dual-format track with the Atmos preference on asks the Atmos rung first through the
	/// HLS route, and the stored file is the Atmos rendition. The preference chooses the rung,
	/// it no longer moves the track off HLS.
	func testDualFormatTrackWithAtmosPreferenceTakesTheAtmosRungThroughHLS() async throws {
		let trackId = 779_000_002
		offlineLibrary.defaults.set(true, forKey: "offlinePreferDolbyAtmos")
		_ = try makeLibraryDirectory()
		let playlist = try makeLocalPlaylist(in: offlineLibrary.root)

		let session = try makeSession()
		let offline = session.helpers.offline
		XCTAssertTrue(offline.preferDolbyAtmos, "this test is about the Atmos preference being on")

		var asked: [HLSRung] = []
		offline.resolveOfflineHLSPlaylist = { _, rung in
			asked.append(rung)
			return playlist
		}
		let streams = Counter()
		let fixture = try silentM4AFixture()
		offline.resolveOfflineStream = { _ in
			streams.value += 1
			return AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: true)
		}

		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(asked, [.dolbyAtmos], "the Atmos preference must make the Atmos rung the first asked")
		XCTAssertEqual(streams.value, 0, "the Atmos rung is served through HLS, so the direct stream is not needed")
		XCTAssertEqual(
			try libraryFileNames(),
			["\(trackId).atmos.m4a"],
			"a dual-format track with the preference on must be stored as Atmos"
		)

		asked.removeAll()
		offline.setOfflineTracksForTesting([makeDualFormatTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertTrue(asked.isEmpty, "the stored Atmos file must satisfy the wish, so a second sync must not resolve the track again")
		XCTAssertEqual(streams.value, 0, "the HLS route must stay used on both passes")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).atmos.m4a"])
	}

	/// An Atmos-only track (no advertised stereo) still resolves through HLS: the manifest
	/// API serves the Atmos rendition, so the ladder ends at the Atmos rung and the file lands
	/// as Atmos rather than failing the sync.
	func testAnAtmosOnlyTrackResolvesThroughHLSAndStoresTheAtmosFile() async throws {
		let trackId = 779_000_030
		let libraryDirectory = try makeLibraryDirectory()
		let initSegment = try eac3InitFixture()
		let playlist = try makeLocalPlaylist(in: offlineLibrary.root, initData: initSegment)

		let session = try makeSession()
		let offline = session.helpers.offline
		var asked: [HLSRung] = []
		offline.resolveOfflineHLSPlaylist = { _, rung in
			asked.append(rung)
			if rung == .dolbyAtmos { return playlist }
			throw HLSStreamError.requestRefused(status: 403)
		}

		offline.setOfflineTracksForTesting([makeTrack(id: trackId, audioModes: [.dolbyAtmos])])
		await offline.awaitOngoingSync()

		XCTAssertEqual(
			asked,
			[.stereo(.high), .stereo(.medium), .stereo(.low), .dolbyAtmos],
			"the stereo rungs are refused, so the Atmos rung is the fallback that plays"
		)
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).atmos.m4a"])

		let stored = libraryDirectory.appendingPathComponent("\(trackId).atmos.m4a")
		XCTAssertTrue(
			HLSStreaming.isPlayableMP4File(at: stored),
			"the stored E-AC-3 file must verify, so the Atmos download is not left unplayable"
		)
		let streamValue = await offline.stream(for: makeTrack(id: trackId, audioModes: [.dolbyAtmos]))
		let stream = try XCTUnwrap(streamValue, "the stored Atmos file must be served offline")
		XCTAssertEqual(stream.url.lastPathComponent, "\(trackId).atmos.m4a")
		XCTAssertTrue(stream.isDolbyAtmos, "the stored Atmos file must be served as Atmos")
	}

	// MARK: - Quality ladder

	/// The offline quality is a ceiling too: a Max wish whose hi-res tier is refused downloads
	/// the best available tier rather than failing the sync.
	func testTheOfflineSyncStepsDownWhenTheConfiguredTierIsRefused() async throws {
		let trackId = 779_000_020
		_ = try makeLibraryDirectory()
		let playlist = try makeLocalPlaylist(in: offlineLibrary.root)

		let session = try makeSession(quality: .max)
		let offline = session.helpers.offline
		var asked: [HLSRung] = []
		offline.resolveOfflineHLSPlaylist = { _, rung in
			asked.append(rung)
			if rung == .stereo(.max) { throw HLSStreamError.requestRefused(status: 403) }
			return playlist
		}

		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(asked, [.stereo(.max), .stereo(.high)], "the offline resolve asks Max then steps down to Lossless")
		XCTAssertEqual(
			try libraryFileNames(), ["\(trackId).lossless.m4a"],
			"a track added offline at Max must download its best available tier under the tier that served"
		)
	}

	/// The served tier names the file, and the variant check agrees: the stored lossless file is a
	/// tier the Max ladder can serve, so the next sync accepts it without resolving the track again.
	/// (Before the 2026-10-08 decision this test asserted the opposite — that a second sync
	/// re-resolved to allow an upgrade; that per-sync probe was the cost being removed.)
	func testASteppedDownOfflineFileIsStoredAndKeptUnderTheServedTier() async throws {
		let trackId = 779_000_021
		let libraryDirectory = try makeLibraryDirectory()
		let playlist = try makeLocalPlaylist(in: offlineLibrary.root)

		let session = try makeSession(quality: .max)
		let offline = session.helpers.offline
		var asked: [HLSRung] = []
		offline.resolveOfflineHLSPlaylist = { _, rung in
			asked.append(rung)
			if rung == .stereo(.max) { throw HLSStreamError.requestRefused(status: 403) }
			return playlist
		}

		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(asked, [.stereo(.max), .stereo(.high)])
		let fileURL = libraryDirectory.appendingPathComponent("\(trackId).lossless.m4a")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).lossless.m4a"], "the file must be named for the tier that was served")

		// A marker the rewrite would move if the sync downloaded the track again.
		let marker = Date(timeIntervalSince1970: 1_000_000_000)
		try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: fileURL.path)
		asked.removeAll()

		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertTrue(asked.isEmpty, "the stored lossless file is a tier the Max ladder can serve, so a second sync must not resolve the track again")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).lossless.m4a"], "the served-tier file must be recognised, not replaced")
		let after = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
		XCTAssertEqual(after, marker, "the sync must not rewrite a file it already has")
	}

	/// An Atmos-advertised track with the preference off is served the stereo rendition through the
	/// ladder (the manifest API answers it FLAC, measured for 241,647,167). The old acceptance
	/// counted only the Atmos variant, so this shape was re-resolved on every sync.
	func testAnAtmosAdvertisedTrackStoredAsStereoIsAcceptedNextSync() async throws {
		let trackId = 779_000_022
		_ = try makeLibraryDirectory()
		let playlist = try makeLocalPlaylist(in: offlineLibrary.root)

		let session = try makeSession(quality: .max)
		let offline = session.helpers.offline
		var asked: [HLSRung] = []
		offline.resolveOfflineHLSPlaylist = { _, rung in
			asked.append(rung)
			if rung == .stereo(.max) { throw HLSStreamError.requestRefused(status: 403) }
			return playlist
		}

		// Atmos-only: no advertised stereo, but the manifest serves FLAC for it.
		offline.setOfflineTracksForTesting([makeTrack(id: trackId, audioModes: [.dolbyAtmos])])
		await offline.awaitOngoingSync()

		XCTAssertEqual(asked, [.stereo(.max), .stereo(.high)], "the stereo ladder serves this track, so the file is stereo")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).lossless.m4a"])

		asked.removeAll()
		offline.setOfflineTracksForTesting([makeTrack(id: trackId, audioModes: [.dolbyAtmos])])
		await offline.awaitOngoingSync()

		XCTAssertTrue(asked.isEmpty, "the stereo file the ladder served must be accepted, not re-resolved every sync")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).lossless.m4a"])
	}

	/// The direct-stream fallback's tier is always one the ceiling's ladder already holds, so
	/// `acceptableVariants` needs no variant of its own: the stereo rungs are exactly the ladder,
	/// and the served tier never rises above the request. Proven for every ceiling and preference.
	func testTheDirectStreamTierIsAlreadyOnTheCeilingLadder() {
		let advertisedQualities: [AudioQuality?] = [nil, .low, .medium, .high, .max]
		for ceiling in AudioQuality.allCases {
			for prefer in [false, true] {
				let stereoRungs = HLSStreaming.rungs(
					for: ceiling, preferDolbyAtmos: prefer, trackHasDolbyAtmos: true
				).compactMap { rung -> AudioQuality? in
					if case .stereo(let quality) = rung { return quality }
					return nil
				}
				XCTAssertEqual(
					Set(stereoRungs), Set(HLSStreaming.qualityLadder(for: ceiling)),
					"the stereo rungs are the ceiling's ladder, whatever the Atmos preference"
				)
				for advertised in advertisedQualities {
					let served = ceiling.servedByDirectStream(advertised: advertised)
					XCTAssertTrue(
						stereoRungs.contains(served),
						"the \(served.rawValue) the direct stream serves under a \(ceiling.rawValue) ceiling must already be on the ladder"
					)
				}
			}
		}
	}

	/// The offline stream carries the tier the stored file holds, so the badge reads the file and
	/// not the track's advertised quality. A 24-bit legacy file on a `LOSSLESS`-advertised track
	/// must report 24-bit rather than 16-bit.
	func testAnOfflineStreamReportsTheStoredFileTierNotTheAdvertisedOne() async throws {
		let trackId = 779_000_024
		let libraryDirectory = try makeLibraryDirectory()
		// `makeTrack` advertises `.high`; the file is a legacy 24-bit FLAC.
		try Data(repeating: 3, count: 600).write(to: libraryDirectory.appendingPathComponent("\(trackId).hires.flac"))

		let session = try makeSession(quality: .max)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		let streamValue = await offline.stream(for: makeTrack(id: trackId))
		let stream = try XCTUnwrap(streamValue)
		XCTAssertEqual(stream.url.lastPathComponent, "\(trackId).hires.flac")
		XCTAssertEqual(stream.quality, .max, "the stream must carry the file's tier, not the advertised LOSSLESS")
		XCTAssertEqual(HLSStreaming.badge(for: .stereo(try XCTUnwrap(stream.quality))), "24-bit")
	}

	/// Two files for one track resolve deterministically: the wanted variant first, then the best
	/// stereo tier the ceiling's ladder can serve, then the file name. The sync keeps the same file
	/// the stream would play.
	func testTheOfflineFileForATrackIsChosenDeterministically() async throws {
		let trackId = 779_000_025
		let libraryDirectory = try makeLibraryDirectory()
		// Write the lower tier first, so directory order would pick it if the rule were `files[0]`.
		try Data(repeating: 4, count: 600).write(to: libraryDirectory.appendingPathComponent("\(trackId).high.m4a"))
		try FileManager.default.copyItem(
			at: try silentM4AFixture(),
			to: libraryDirectory.appendingPathComponent("\(trackId).lossless.m4a")
		)

		let session = try makeSession(quality: .max)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		// Max's ladder is [max, high, medium, low]; `.lossless` (high) is the best tier present and
		// must win, whatever the directory order.
		let streamValue = await offline.stream(for: makeTrack(id: trackId))
		let stream = try XCTUnwrap(streamValue)
		XCTAssertEqual(stream.url.lastPathComponent, "\(trackId).lossless.m4a", "the best tier on the ladder must win deterministically")
		XCTAssertEqual(stream.quality, .high)
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).lossless.m4a"], "the sync must prune the file it did not keep")
	}

	// MARK: - Legacy files

	/// A 24-bit file written before the HLS rewrite carries the `hires` marker. At Max it is
	/// the wanted variant, so the sync must keep it instead of re-downloading it as a lossless
	/// file.
	func testALegacyHiresFileSatisfiesAMaxWish() async throws {
		let trackId = 779_000_010
		let libraryDirectory = try makeLibraryDirectory()
		let hires = libraryDirectory.appendingPathComponent("\(trackId).hires.flac")
		try Data(repeating: 1, count: 64).write(to: hires)

		let session = try makeSession(quality: .max)
		let offline = session.helpers.offline
		let downloads = Counter()
		offline.resolveOfflineHLSPlaylist = { _, _ in
			downloads.value += 1
			return URL(string: "https://example.invalid/master.m3u8")!
		}

		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(downloads.value, 0, "the hires file must satisfy the Max wish, so nothing downloads")
		XCTAssertEqual(try libraryFileNames(), ["\(trackId).hires.flac"])
	}

	// MARK: - Orphaned temporaries

	/// A hard crash mid-download leaves the hidden temporary sibling in the library. The sync
	/// clears it, since nothing else can parse a leading dot or reach it through `removeAll`.
	func testTheSyncRemovesCrashOrphanedTemporaryFiles() async throws {
		let trackId = 779_000_011
		let libraryDirectory = try makeLibraryDirectory()
		let orphan = libraryDirectory.appendingPathComponent(".\(trackId).lossless.m4a.tmp-AB12CD")
		try Data(repeating: 2, count: 64).write(to: orphan)

		let session = try makeSession()
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([])
		await offline.awaitOngoingSync()

		XCTAssertFalse(
			FileManager.default.fileExists(atPath: orphan.path),
			"the sync must clear a temporary sibling a crash left behind"
		)
	}

	// MARK: - Helpers

	private final class Counter {
		var value = 0
	}

	private func makeLibraryDirectory() throws -> URL {
		let libraryDirectory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
		return libraryDirectory
	}

	private func libraryFileNames() throws -> [String] {
		let directory = offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library")
		return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	private func silentM4AFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "m4a", subdirectory: "Fixtures"))
	}

	/// The 588-byte `ftyp` + `moov` initialization segment Tidal serves for an `EAC3_JOC`
	/// variant, so the Atmos download is exercised with real E-AC-3 bytes and no network.
	private func eac3InitFixture() throws -> Data {
		try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "eac3-init", withExtension: "mp4", subdirectory: "Fixtures")))
	}

	/// A local stand-in for Tidal's CDN: a master playlist, a variant playlist and the pieces of
	/// a real m4a file split across an initialization segment and one media segment, so the
	/// assembled result is the source file byte for byte and decodes.
	private func makeLocalPlaylist(in root: URL, initData: Data? = nil) throws -> URL {
		let directory = root.appendingPathComponent("cdn-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		if let initData {
			try initData.write(to: directory.appendingPathComponent("init.mp4"))
			try Data(repeating: 0xAB, count: 4096).write(to: directory.appendingPathComponent("seg-1.mp4"))
		} else {
			let data = try Data(contentsOf: try silentM4AFixture())
			let split = min(1024, data.count)
			try data.prefix(split).write(to: directory.appendingPathComponent("init.mp4"))
			try data.dropFirst(split).write(to: directory.appendingPathComponent("seg-1.mp4"))
		}
		let mediaPlaylist = [
			"#EXTM3U",
			"#EXT-X-TARGETDURATION:4",
			"#EXT-X-MAP:URI=\"init.mp4\"",
			"#EXTINF:4.000,",
			"seg-1.mp4",
			"#EXT-X-ENDLIST"
		].joined(separator: "\n")
		try Data(mediaPlaylist.utf8).write(to: directory.appendingPathComponent("variant.m3u8"))
		let master = ["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=1596037,CODECS=\"fLaC\"", "variant.m3u8"].joined(separator: "\n")
		let masterURL = directory.appendingPathComponent("master.m3u8")
		try Data(master.utf8).write(to: masterURL)
		return masterURL
	}

	/// A track Tidal advertises as both STEREO and DOLBY_ATMOS, the shape that has a
	/// stereo rendition for the HLS route and an Atmos one for the preference.
	private func makeDualFormatTrack(id: Int) -> Track {
		makeTrack(id: id, audioModes: [.stereo, .dolbyAtmos])
	}

	/// A session whose token carries the `cuk` claim the HLS route needs.
	private func makeSession(quality: AudioQuality = .high) throws -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: try Self.tokenWithCukClaim(),
			refreshToken: "",
			clientID: AuthInformation.DesktopClientID,
			offlineAudioQuality: quality
		))
	}

	private static func tokenWithCukClaim() throws -> String {
		let data = try JSONSerialization.data(withJSONObject: ["uid": 1, "cuk": "client-key"])
		let body = data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
		return "Bearer .\(body).signature"
	}

	private func makeTrack(id: Int, audioModes: [AudioMode] = [.stereo]) -> Track {
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
			editable: false, explicit: false, audioQuality: .high, audioModes: audioModes,
			artist: artist, artists: [artist], album: album, mixes: nil, dateAdded: nil,
			index: nil, itemUuid: nil, bpm: nil, key: nil, keyScale: nil
		)
	}
}
