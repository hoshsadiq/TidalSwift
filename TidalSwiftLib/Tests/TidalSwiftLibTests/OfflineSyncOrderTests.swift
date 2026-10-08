//
//  OfflineSyncOrderTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 05.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// The sync must never delete a file it cannot replace: downloads happen first, and a
/// track's old file goes only once its replacement is on disk.
@MainActor
final class OfflineSyncOrderTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineSyncOrder")

	override func tearDown() {
		displayErrorHandler = nil
		offlineLibrary.remove()
		super.tearDown()
	}

	func testFailedQualitySwitchKeepsTheExistingFile() async throws {
		let trackId = 778_000_001
		let libraryDirectory = try makeLibraryDirectory()
		// Already on disk at quality A (".high" is stored as `<id>.lossless.flac`)
		let existingFile = libraryDirectory.appendingPathComponent("\(trackId).lossless.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		// Sync at quality B (".medium" is stored as `<id>.high.m4a`)
		let session = makeSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		// A replacement that resolves to a file which cannot be downloaded is the
		// failing download the bug is about, without needing a live account.
		offline.resolveOfflineStream = { _ in
			AudioStream(
				url: URL(fileURLWithPath: NSTemporaryDirectory())
					.appendingPathComponent("missing-\(UUID().uuidString).flac"),
				pathExtension: "flac",
				isDolbyAtmos: false
			)
		}

		await offline.awaitOngoingSync()

		XCTAssertTrue(
			FileManager.default.fileExists(atPath: existingFile.path),
			"the sync deleted the old-quality file although its replacement failed"
		)
		let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
		XCTAssertEqual(files, ["\(trackId).lossless.flac"])
	}

	func testSuccessfulQualitySwitchReplacesTheFile() async throws {
		let trackId = 778_000_002
		let libraryDirectory = try makeLibraryDirectory()
		let existingFile = libraryDirectory.appendingPathComponent("\(trackId).lossless.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		let session = makeSession(offlineAudioQuality: .medium)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		let fixture = try silentFlacFixture()
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "flac", isDolbyAtmos: false)
		}

		await offline.awaitOngoingSync()

		let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
		XCTAssertEqual(files, ["\(trackId).high.flac"])
	}

	/// A file below the ceiling is kept, not probed for an upgrade: the per-sync re-resolve was
	/// dropped by decision (2026-10-08), so the sync must not resolve a track whose stored file is
	/// a tier its ceiling's ladder can serve. (This test previously asserted the opposite — that an
	/// upward quality move replaced the lower-tier file; that probe was the cost being removed.)
	func testALowerTierFileIsKeptInsteadOfProbedForAnUpgrade() async throws {
		let trackId = 778_000_003
		let libraryDirectory = try makeLibraryDirectory()
		let existingFile = libraryDirectory.appendingPathComponent("\(trackId).low.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		let session = makeSession(offlineAudioQuality: .max)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		let fixture = try silentFlacFixture()
		let downloads = Counter()
		offline.resolveOfflineStream = { _ in
			downloads.value += 1
			return AudioStream(url: fixture, pathExtension: "flac", isDolbyAtmos: false)
		}

		await offline.awaitOngoingSync()

		XCTAssertEqual(downloads.value, 0, "a below-ceiling file must be kept, not re-resolved every sync")
		let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
		XCTAssertEqual(files, ["\(trackId).low.flac"], "the stored lower-tier file must stay")
	}

	/// A raised Download setting downloads the newly wanted tier: the setting change is what
	/// asks for the re-check, so the flag it sets is the whole mechanism.
	func testRaisingTheQualitySettingDownloadsTheNewlyWantedTier() async throws {
		let trackId = 778_000_004
		let libraryDirectory = try makeLibraryDirectory()
		let existingFile = libraryDirectory.appendingPathComponent("\(trackId).low.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		let session = makeSession(offlineAudioQuality: .low)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()
		XCTAssertEqual(try libraryFileNames(in: libraryDirectory), ["\(trackId).low.flac"], "the low-ceiling sync keeps the low file")

		let fixture = try silentFlacFixture()
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "flac", isDolbyAtmos: false)
		}
		offline.setAudioQuality(to: .max)
		await offline.awaitOngoingSync()

		XCTAssertEqual(
			try libraryFileNames(in: libraryDirectory),
			["\(trackId).hi_res_lossless.flac"],
			"raising the Download setting must replace the lower-tier file"
		)
	}

	/// A wish the settings change asked for survives a pass that failed to fetch the new tier, so
	/// the next sync retries it instead of accepting the old file for good.
	func testAFailedQualityUpgradeIsRetriedOnTheNextSync() async throws {
		let trackId = 778_000_005
		let libraryDirectory = try makeLibraryDirectory()
		let existingFile = libraryDirectory.appendingPathComponent("\(trackId).low.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		let session = makeSession(offlineAudioQuality: .low)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		// This pass cannot resolve the wanted tier, as a network error or a refused rung would not.
		offline.resolveOfflineStream = { _ in nil }
		offline.setAudioQuality(to: .max)
		await offline.awaitOngoingSync()
		XCTAssertEqual(try libraryFileNames(in: libraryDirectory), ["\(trackId).low.flac"], "a failed upgrade keeps the old file")

		// The next pass can, and must, land the wish rather than accept the old tier.
		let fixture = try silentFlacFixture()
		offline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "flac", isDolbyAtmos: false)
		}
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(
			try libraryFileNames(in: libraryDirectory),
			["\(trackId).hi_res_lossless.flac"],
			"a failed upgrade must be retried on the next sync, not forgotten"
		)
	}

	/// A failing download the wish did not reject — a new track with no file — must not keep the
	/// wish alive, or one unfetchable track holds the whole below-wanted library in re-check mode
	/// for ever, which is the per-sync probe this change removed.
	func testAnUnrelatedFailingTrackDoesNotKeepTheQualityWishAlive() async throws {
		let keptId = 778_000_007
		let failingId = 778_000_008
		let libraryDirectory = try makeLibraryDirectory()
		let existingFile = libraryDirectory.appendingPathComponent("\(keptId).low.flac")
		try FileManager.default.copyItem(at: try silentFlacFixture(), to: existingFile)

		let session = makeSession(offlineAudioQuality: .low)
		let offline = session.helpers.offline
		let resolves = Counter()
		offline.resolveOfflineStream = { track in
			guard track.id == keptId else { return nil }
			resolves.value += 1
			// The tier already on disk, so the wish's pass keeps it rather than failing it.
			return AudioStream(url: existingFile, pathExtension: "flac", isDolbyAtmos: false, quality: .low)
		}
		offline.setOfflineTracksForTesting([makeTrack(id: keptId), makeTrack(id: failingId)])
		await offline.awaitOngoingSync()

		offline.setAudioQuality(to: .max)
		await offline.awaitOngoingSync()
		XCTAssertEqual(resolves.value, 1, "the Max wish must re-check the below-wanted file once")

		// The wish must have cleared despite the other track's failure: a plain sync then keeps the
		// below-wanted file instead of re-resolving it every pass.
		offline.setOfflineTracksForTesting([makeTrack(id: keptId), makeTrack(id: failingId)])
		await offline.awaitOngoingSync()
		XCTAssertEqual(resolves.value, 1, "an unrelated failing track must not keep the wish alive")
		XCTAssertEqual(try libraryFileNames(in: libraryDirectory), ["\(keptId).low.flac"])
	}

	/// The wish is "kept until the quality setting changes", so it must survive a relaunch: a
	/// pass that ended before the app quit cannot be the end of it.
	func testAFailedQualityWishSurvivesARelaunch() async throws {
		let trackId = 778_000_009
		let libraryDirectory = try makeLibraryDirectory()
		try FileManager.default.copyItem(
			at: try silentFlacFixture(),
			to: libraryDirectory.appendingPathComponent("\(trackId).low.flac")
		)

		let firstRun = makeSession(offlineAudioQuality: .low)
		let firstOffline = firstRun.helpers.offline
		firstOffline.resolveOfflineStream = { _ in nil }
		firstOffline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		firstOffline.setAudioQuality(to: .max)
		await firstOffline.awaitOngoingSync()
		XCTAssertEqual(try libraryFileNames(in: libraryDirectory), ["\(trackId).low.flac"], "a failed upgrade keeps the old file")

		// A relaunch on the same library: the wish lives in the offline store, not the session.
		let secondRun = makeSession(offlineAudioQuality: .max)
		let secondOffline = secondRun.helpers.offline
		let fixture = try silentFlacFixture()
		secondOffline.resolveOfflineStream = { _ in
			AudioStream(url: fixture, pathExtension: "flac", isDolbyAtmos: false)
		}
		secondOffline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await secondOffline.awaitOngoingSync()

		XCTAssertEqual(
			try libraryFileNames(in: libraryDirectory),
			["\(trackId).hi_res_lossless.flac"],
			"the wish must survive a relaunch, so the next pass lands it"
		)
	}

	/// A failed download's message must not carry the failing URL: its query holds a token, and
	/// the message reaches the app's toast and the console.
	func testAFailedDownloadMessageCarriesNoURL() async throws {
		let trackId = 778_000_006
		let sentinel = "SENTINEL-TOKEN-9f2c"

		var messages: [String] = []
		displayErrorHandler = { _, content in messages.append(content) }

		let session = makeSession(offlineAudioQuality: .high)
		let offline = session.helpers.offline
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		offline.resolveOfflineStream = { _ in
			// A stand-in for a signed segment URL: the failure carries the full URL.
			AudioStream(
				url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(sentinel).flac"),
				pathExtension: "flac",
				isDolbyAtmos: false
			)
		}

		await offline.awaitOngoingSync()

		XCTAssertFalse(messages.isEmpty, "the failed download must report an error")
		// The download path's own message, not `reportMissingDownloadSource`'s fixed text: a
		// failure that never reached the network write would satisfy "no URL" too.
		XCTAssertTrue(
			messages.allSatisfy { $0.hasPrefix("Network error:") },
			"the message must come from the download failure, not the missing-source report"
		)
		// The message itself is deliberately not echoed: it is the thing under test, and a real one
		// would carry a signed URL's token.
		XCTAssertTrue(
			messages.allSatisfy { !$0.contains(sentinel) && !$0.contains("://") },
			"a failed download's message must not carry the failing URL"
		)
	}

	/// The sticky wish re-checks the tracks it rejected and nothing else. One replacement that
	/// cannot resolve must not put the whole below-wanted library back on the per-sync probe that
	/// this branch removed, so the later pass resolves only the stuck one.
	func testAStuckReplacementDoesNotReResolveTheRestOfTheLibrary() async throws {
		let stuckId = 778_000_010
		let settledIdA = 778_000_011
		let settledIdB = 778_000_012
		let libraryDirectory = try makeLibraryDirectory()
		for trackId in [stuckId, settledIdA, settledIdB] {
			try FileManager.default.copyItem(
				at: try silentFlacFixture(),
				to: libraryDirectory.appendingPathComponent("\(trackId).low.flac")
			)
		}

		let session = makeSession(offlineAudioQuality: .low)
		let offline = session.helpers.offline
		let resolves = Counter()
		offline.resolveOfflineStream = { track in
			resolves.value += 1
			// The stuck track's replacement cannot resolve; the other two are served only at the tier
			// already on disk, so they settle rather than keep the wish alive.
			guard track.id != stuckId else { return nil }
			return AudioStream(
				url: libraryDirectory.appendingPathComponent("\(track.id).low.flac"),
				pathExtension: "flac",
				isDolbyAtmos: false,
				quality: .low
			)
		}
		let tracks = [stuckId, settledIdA, settledIdB].map { makeTrack(id: $0) }
		offline.setOfflineTracksForTesting(tracks)
		await offline.awaitOngoingSync()
		XCTAssertEqual(resolves.value, 0, "the launch sync keeps the below-ceiling files without resolving them")

		offline.setAudioQuality(to: .max)
		await offline.awaitOngoingSync()
		XCTAssertEqual(resolves.value, 3, "the settings change re-checks every below-wanted file once")

		offline.setOfflineTracksForTesting(tracks)
		await offline.awaitOngoingSync()
		XCTAssertEqual(
			resolves.value, 4,
			"a later pass must re-resolve only the stuck rejection, not the whole below-wanted library"
		)
		XCTAssertEqual(
			try libraryFileNames(in: libraryDirectory),
			["\(settledIdA).low.flac", "\(settledIdB).low.flac", "\(stuckId).low.flac"].sorted()
		)
	}

	/// The offline ceiling refuses the Atmos rendition, so below High the stereo file is the wanted
	/// variant and the Atmos file is the one pruned. The consequence is unservability, not a wrong
	/// badge: with the Atmos file kept and the stereo file gone, every play ceiling below High
	/// refuses the only file left, and the track cannot play at all.
	func testALowOfflineCeilingKeepsTheStereoFileAndPrunesTheAtmosOne() async throws {
		let trackId = 778_000_013
		let libraryDirectory = try makeLibraryDirectory()
		let track = makeDualFormatTrack(id: trackId)
		let session = makeSession(offlineAudioQuality: .low)
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { _ in nil }
		offline.setOfflineTracksForTesting([track])
		await offline.awaitOngoingSync()

		// Both renditions on disk, as a ceiling drop from High would leave them.
		try FileManager.default.copyItem(
			at: try silentM4AFixture(),
			to: libraryDirectory.appendingPathComponent("\(trackId).atmos.m4a")
		)
		try FileManager.default.copyItem(
			at: try silentM4AFixture(),
			to: libraryDirectory.appendingPathComponent("\(trackId).low.m4a")
		)

		offline.setPreferDolbyAtmos(to: true)
		await offline.awaitOngoingSync()

		let streamValue = await offline.stream(for: track, ceiling: .low)
		let stream = try XCTUnwrap(
			streamValue,
			"the stereo file must survive the wish, or the kept Atmos file leaves the track unservable below High"
		)
		XCTAssertFalse(stream.isDolbyAtmos)
		XCTAssertEqual(try libraryFileNames(in: libraryDirectory), ["\(trackId).low.m4a"])
	}

	/// A direct-stream download is named for the tier that path served, not the tier that was asked
	/// for: a Max request the endpoint answers with the 16-bit lossless file must land as
	/// `<id>.lossless.m4a`, or the name disagrees with the file and the next sync re-resolves it.
	func testADirectStreamDownloadIsNamedForTheServedTier() async throws {
		let trackId = 778_000_014
		let libraryDirectory = try makeLibraryDirectory()
		let session = makeSession(offlineAudioQuality: .max)
		let offline = session.helpers.offline
		let fixture = try silentM4AFixture()
		offline.resolveOfflineStream = { _ in
			// The 16-bit lossless answer to a Max request, the direct stream's measured behaviour.
			AudioStream(url: fixture, pathExtension: "m4a", isDolbyAtmos: false, quality: .high)
		}
		offline.setOfflineTracksForTesting([makeTrack(id: trackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(
			try libraryFileNames(in: libraryDirectory),
			["\(trackId).lossless.m4a"],
			"the name must carry the tier that was served, not the configured Max ceiling"
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

	private func libraryFileNames(in directory: URL) throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	private func silentFlacFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "flac", subdirectory: "Fixtures"))
	}

	private func silentM4AFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "m4a", subdirectory: "Fixtures"))
	}

	/// The session owns the `Offline` the sync runs on (its reference is `unowned`), so
	/// build both and hold the session in a local; setup must stay synchronous.
	private func makeSession(offlineAudioQuality: AudioQuality) -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: offlineAudioQuality
		))
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
			audioQuality: nil, audioModes: [.stereo], artist: artist, artists: nil
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

	/// A track Tidal advertises as both STEREO and DOLBY_ATMOS, so both renditions are on its
	/// ladder and one can be the wanted variant.
	private func makeDualFormatTrack(id: Int) -> Track {
		makeTrack(id: id, audioModes: [.stereo, .dolbyAtmos])
	}
}
