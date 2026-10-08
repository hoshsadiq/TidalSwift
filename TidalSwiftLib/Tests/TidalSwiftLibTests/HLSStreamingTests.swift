//
//  HLSStreamingTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins how a Tidal HLS manifest is read, assembled and cached: the master playlist
/// names the variant, the media playlist names the initialization segment and the media
/// segments, and the concatenation has to be byte-exact or the file plays a few seconds
/// and stops.
@MainActor
final class HLSStreamingTests: XCTestCase {
	private var directory: URL!
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "HLSStreaming")

	override func setUp() {
		super.setUp()
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("HLSStreamingTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: directory)
		directory = nil
		offlineLibrary.remove()
		super.tearDown()
	}

	// MARK: - Playlist parsing

	func testMultivariantPlaylistWithOneVariantIsRead() throws {
		let playlist = try parse("""
		#EXTM3U
		#EXT-X-STREAM-INF:BANDWIDTH=1596037,AVERAGE-BANDWIDTH=1638279,CODECS="fLaC"
		variant.m3u8
		""")

		XCTAssertEqual(playlist, .multivariant(variants: [
			HLSVariant(
				bandwidth: 1_596_037,
				codecs: "fLaC",
				url: URL(string: "https://im-fa.manifest.tidal.com/variant.m3u8")!
			)
		]))
	}

	/// A quoted `CODECS` value carries a comma, so the attribute split must not cut it.
	func testMultivariantPlaylistWithSeveralVariantsReadsEveryBandwidthAndCodec() throws {
		let playlist = try parse("""
		#EXTM3U
		#EXT-X-STREAM-INF:BANDWIDTH=98183,CODECS="mp4a.40.5"
		low.m3u8
		#EXT-X-STREAM-INF:BANDWIDTH=324274,CODECS="mp4a.40.2"
		medium.m3u8
		#EXT-X-STREAM-INF:BANDWIDTH=1596037,CODECS="fLaC"
		max.m3u8
		""")

		guard case .multivariant(let variants) = playlist else {
			return XCTFail("a multivariant playlist must parse as multivariant, got \(playlist)")
		}
		XCTAssertEqual(variants.map(\.bandwidth), [98_183, 324_274, 1_596_037])
		XCTAssertEqual(variants.map(\.codecs), ["mp4a.40.5", "mp4a.40.2", "fLaC"])
	}

	/// One format is requested per play, so a master should hold one variant; when Tidal
	/// still offers several, the highest bandwidth wins rather than the first line.
	func testHighestBandwidthVariantWinsRegardlessOfPlaylistOrder() throws {
		let variants = [
			HLSVariant(bandwidth: 324_274, codecs: "mp4a.40.2", url: URL(string: "https://x/medium.m3u8")!),
			HLSVariant(bandwidth: 1_596_037, codecs: "fLaC", url: URL(string: "https://x/max.m3u8")!),
			HLSVariant(bandwidth: 98_183, codecs: "mp4a.40.5", url: URL(string: "https://x/low.m3u8")!)
		]

		XCTAssertEqual(try HLSStreaming.highestBandwidthVariant(in: variants).url.absoluteString, "https://x/max.m3u8")
		XCTAssertThrowsError(try HLSStreaming.highestBandwidthVariant(in: [])) { error in
			XCTAssertEqual(error as? HLSStreamError, .noVariants)
		}
	}

	func testMediaPlaylistIsRead() throws {
		let playlist = try parse("""
		#EXTM3U
		#EXT-X-VERSION:7
		#EXT-X-TARGETDURATION:4
		#EXT-X-MEDIA-SEQUENCE:0
		#EXTINF:4.000,
		seg-1.mp4
		#EXTINF:4.000,
		seg-2.mp4
		#EXT-X-ENDLIST
		""")

		XCTAssertEqual(playlist, .media(HLSMediaPlaylist(initializationURL: nil, segmentURLs: [
			URL(string: "https://im-fa.manifest.tidal.com/seg-1.mp4")!,
			URL(string: "https://im-fa.manifest.tidal.com/seg-2.mp4")!
		])))
	}

	func testMediaPlaylistWithInitializationSegmentIsRead() throws {
		let playlist = try parse("""
		#EXTM3U
		#EXT-X-TARGETDURATION:4
		#EXT-X-MAP:URI="init.mp4"
		#EXTINF:4.000,
		seg-1.mp4
		#EXT-X-ENDLIST
		""")

		guard case .media(let media) = playlist else {
			return XCTFail("a media playlist must parse as media, got \(playlist)")
		}
		XCTAssertEqual(media.initializationURL?.absoluteString, "https://im-fa.manifest.tidal.com/init.mp4")
		XCTAssertEqual(media.segmentURLs.map(\.lastPathComponent), ["seg-1.mp4"])
	}

	/// A malformed playlist is refused, not read as an empty one that would assemble to
	/// a zero-byte file.
	func testMalformedPlaylistIsRefused() {
		for text in ["", "hello", "#EXTM3U", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1596037"] {
			XCTAssertThrowsError(try parse(text)) { error in
				XCTAssertEqual(error as? HLSStreamError, .malformedPlaylist, "for \(text.debugDescription)")
			}
		}
	}

	/// An insecure playlist URL could only enter through the manifest.
	func testPlaylistURIsAreUpgradedToHTTPS() throws {
		let playlist = try HLSPlaylistParser.parse("""
		#EXTM3U
		#EXT-X-STREAM-INF:BANDWIDTH=1596037,CODECS="fLaC"
		http://im-fa.manifest.tidal.com/variant.m3u8
		""", baseURL: URL(string: "http://im-fa.manifest.tidal.com/master.m3u8")!)

		guard case .multivariant(let variants) = playlist else { return XCTFail("expected a master") }
		XCTAssertEqual(variants.first?.url.absoluteString, "https://im-fa.manifest.tidal.com/variant.m3u8")
	}

	// MARK: - Assembly

	/// Each piece is a distinct byte so a reordered assembly fails.
	func testAssemblyConcatenatesInitAndSegmentsInOrder() async throws {
		let source = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let output = directory.appendingPathComponent("out", isDirectory: true)
		let trackId = 981_563_401

		let cached = try await HLSStreaming.downloadToCache(
			source.multivariantURL, forTrackId: trackId, rung: .stereo(.max),
			cacheDirectory: output, fetch: fileFetcher
		)

		XCTAssertEqual(cached.lastPathComponent, "\(trackId)-HI_RES_LOSSLESS.m4a")
		let expected = source.initBytes + Data("AAAA".utf8) + Data("BBBB".utf8)
		XCTAssertEqual(try Data(contentsOf: cached), expected)
	}

	/// A master that is already a media playlist is assembled directly, which is the
	/// shape a single-format request may come back in.
	func testMediaPlaylistPassedAsTheTopLevelPlaylistIsAssembled() async throws {
		let source = try makeLocalPlaylist(segments: ["AAAA", "BBBB"], topLevelIsMediaPlaylist: true)
		let output = directory.appendingPathComponent("out", isDirectory: true)

		let cached = try await HLSStreaming.downloadToCache(
			source.multivariantURL, forTrackId: 981_563_402, rung: .stereo(.max),
			cacheDirectory: output, fetch: fileFetcher
		)

		let expected = source.initBytes + Data("AAAA".utf8) + Data("BBBB".utf8)
		XCTAssertEqual(try Data(contentsOf: cached), expected)
	}

	/// An interrupted download must leave nothing behind, so it can never look cached and
	/// complete to a later play.
	func testInterruptedAssemblyLeavesNothingAtTheDestination() async throws {
		let source = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let output = directory.appendingPathComponent("out", isDirectory: true)
		let destination = PlaybackCache.fileURL(forTrackId: 981_563_403, rung: .stereo(.max), in: output)

		do {
			try await HLSStreaming.downloadToCache(
				source.multivariantURL, forTrackId: 981_563_403, rung: .stereo(.max),
				cacheDirectory: output, fetch: { url in
					if url.lastPathComponent == "seg-2.mp4" { throw HLSStreamError.fetchFailed(host: "cdn") }
					return try Data(contentsOf: url)
				}
			)
			XCTFail("a missing segment must fail the download")
		} catch {
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "an interrupted download must leave no file")
		let leftovers = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
			.filter { $0.lastPathComponent.contains(".tmp-") }
		XCTAssertTrue(leftovers.isEmpty, "an interrupted download must leave no temporary file behind")
	}

	/// Bytes that are not an MP4 stream are refused instead of installed as a track.
	func testAssemblyRefusesBytesWithoutAnMP4Header() async throws {
		let source = try makeLocalPlaylist(segments: ["AAAA", "BBBB"], initBytes: Data(repeating: 0x41, count: 1024))
		let output = directory.appendingPathComponent("out", isDirectory: true)
		let destination = PlaybackCache.fileURL(forTrackId: 981_563_404, rung: .stereo(.max), in: output)

		do {
			try await HLSStreaming.downloadToCache(
				source.multivariantURL, forTrackId: 981_563_404, rung: .stereo(.max),
				cacheDirectory: output, fetch: fileFetcher
			)
			XCTFail("bytes without an MP4 header must be refused")
		} catch {
			XCTAssertEqual(error as? HLSStreamError, .notPlayableFile)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
	}

	func testMediaPlaylistWithoutAnInitializationSegmentIsRefused() async throws {
		let media = HLSMediaPlaylist(initializationURL: nil, segmentURLs: [URL(string: "https://cdn/seg-1.mp4")!])
		do {
			try await HLSStreaming.assemble(media, to: directory.appendingPathComponent("out.m4a"), fetch: { _ in Data() })
			XCTFail("a media playlist without an init segment must be refused")
		} catch {
			XCTAssertEqual(error as? HLSStreamError, .missingInitializationSegment)
		}
	}

	// MARK: - Cache

	/// Streaming an uncached track hands the playlist back at once, and the same track is
	/// written to the cache behind the play so a later play reads the file.
	func testStreamingAnUncachedTrackReturnsThePlaylistAndCachesInTheBackground() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let trackId = 981_563_405

		let playback = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in local.multivariantURL }, fetch: fileFetcher
		)

		let source = try XCTUnwrap(playback)
		XCTAssertEqual(source.url, local.multivariantURL, "an uncached play starts from the playlist")
		XCTAssertNil(source.sampleRate, "a playlist reports no format")

		let download = try XCTUnwrap(source.backgroundDownload)
		let cacheURL = await download.value
		XCTAssertEqual(cacheURL?.lastPathComponent, "\(trackId)-HI_RES_LOSSLESS.m4a")
		let expected = local.initBytes + Data("AAAA".utf8) + Data("BBBB".utf8)
		XCTAssertEqual(
			try Data(contentsOf: XCTUnwrap(cacheURL)), expected,
			"the background write must be the assembled track"
		)
	}

	/// Hermetic: the cache check runs before resolution, so a hit never opens a
	/// connection and a regression that skipped the check would fail its fetch instead.
	func testPlaybackSourceReturnsTheCachedFileWithoutResolvingOrFetching() async throws {
		let trackId = 981_563_406
		let cached = PlaybackCache.fileURL(forTrackId: trackId, rung: .stereo(.max), in: directory)
		try validMP4Bytes().write(to: cached)

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in
				XCTFail("a cached file must not resolve a playlist")
				throw HLSStreamError.requestFailed
			},
			fetch: { url in
				XCTFail("a cached file must not fetch \(url)")
				throw HLSStreamError.requestFailed
			}
		)

		XCTAssertEqual(source?.url, cached)
		XCTAssertNil(source?.backgroundDownload, "a cached file must not start a download")
	}

	/// A manifest Tidal refuses resolves no source, so the caller walks to the next
	/// route instead of playing nothing.
	func testRefusedManifestResolvesNoSource() async throws {
		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: 981_563_411), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in throw HLSStreamError.requestRefused(status: 403) },
			fetch: fileFetcher
		)

		XCTAssertNil(source, "a refused manifest must fall through to the next route")
		XCTAssertTrue(
			try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty,
			"a refused manifest must leave nothing cached"
		)
	}

	// MARK: - Atmos rung

	/// A track Tidal advertises as Atmos-only still plays: every stereo rung is refused, the
	/// Atmos rung is served, and the file is cached under the Atmos marker.
	func testAnAtmosOnlyTrackResolvesTheAtmosRungThroughHLS() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let trackId = 981_563_430
		var asked: [HLSRung] = []

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId, audioModes: [.dolbyAtmos]), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, rung in
				asked.append(rung)
				guard rung == .dolbyAtmos else { throw HLSStreamError.requestRefused(status: 403) }
				return local.multivariantURL
			},
			fetch: fileFetcher
		)

		XCTAssertEqual(asked, [.stereo(.max), .stereo(.high), .stereo(.medium), .stereo(.low), .dolbyAtmos])
		let resolved = try XCTUnwrap(source)
		XCTAssertEqual(resolved.rung, .dolbyAtmos)
		XCTAssertEqual(HLSStreaming.badge(for: resolved.rung), "Dolby Atmos")
		let cached = await resolved.backgroundDownload?.value
		XCTAssertEqual(cached?.lastPathComponent, "\(trackId)-DOLBY_ATMOS.m4a")
	}

	/// With the preference on, the Atmos rung is asked first and a served Atmos stops the walk.
	func testTheAtmosPreferenceAsksTheAtmosRungFirst() async throws {
		var asked: [HLSRung] = []
		let served = URL(string: "https://im-fa.manifest.tidal.com/atmos.m3u8")!

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: 981_563_431, audioModes: [.stereo, .dolbyAtmos]), session: makeSession(),
			quality: .max, preferDolbyAtmos: true, cacheDirectory: directory,
			resolvePlaylist: { _, rung in
				asked.append(rung)
				return served
			},
			fetch: fileFetcher
		)

		XCTAssertEqual(asked, [.dolbyAtmos], "the preference must put the Atmos rung first")
		XCTAssertEqual(source?.rung, .dolbyAtmos)
	}

	/// With the preference off, the stereo ladder is asked first and the Atmos rung is the
	/// fallback when every stereo rung is refused, so the track still plays.
	func testWithoutTheAtmosPreferenceTheAtmosRungIsTheFallback() async throws {
		var asked: [HLSRung] = []
		let served = URL(string: "https://im-fa.manifest.tidal.com/atmos.m3u8")!

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: 981_563_432, audioModes: [.stereo, .dolbyAtmos]), session: makeSession(),
			quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, rung in
				asked.append(rung)
				guard rung == .dolbyAtmos else { throw HLSStreamError.requestRefused(status: 403) }
				return served
			},
			fetch: fileFetcher
		)

		XCTAssertEqual(asked, [.stereo(.max), .stereo(.high), .stereo(.medium), .stereo(.low), .dolbyAtmos])
		XCTAssertEqual(source?.rung, .dolbyAtmos)
	}

	/// The rung ladder: stereo is never gated on the advertised modes, and the Atmos rung is
	/// ordered by the preference.
	func testRungsForEachCombination() {
		XCTAssertEqual(
			HLSStreaming.rungs(for: .high, preferDolbyAtmos: false, trackHasDolbyAtmos: false),
			[.stereo(.high), .stereo(.medium), .stereo(.low)]
		)
		XCTAssertEqual(
			HLSStreaming.rungs(for: .high, preferDolbyAtmos: true, trackHasDolbyAtmos: true),
			[.dolbyAtmos, .stereo(.high), .stereo(.medium), .stereo(.low)]
		)
		XCTAssertEqual(
			HLSStreaming.rungs(for: .high, preferDolbyAtmos: false, trackHasDolbyAtmos: true),
			[.stereo(.high), .stereo(.medium), .stereo(.low), .dolbyAtmos]
		)
	}

	/// The badge names the rung that was served, so the Atmos rung reads Dolby Atmos.
	func testBadgeForTheAtmosRung() {
		XCTAssertEqual(HLSStreaming.badge(for: .dolbyAtmos), "Dolby Atmos")
		XCTAssertEqual(HLSStreaming.badge(for: .dolbyAtmos, sampleRate: 44_100), "Dolby Atmos")
	}

	// MARK: - Quality ladder

	/// The quality selector is a ceiling, not an exact tier: each refused rung is the next
	/// lower one, and the first rung served wins without asking anything below it.
	func testTheLadderStepsDownUntilATierIsServedAndAsksNothingLower() async throws {
		var asked: [HLSRung] = []
		let served = URL(string: "https://im-fa.manifest.tidal.com/medium.m3u8")!

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: 981_563_421), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, rung in
				asked.append(rung)
				if rung == .stereo(.medium) { return served }
				throw HLSStreamError.requestRefused(status: 403)
			},
			fetch: fileFetcher
		)

		XCTAssertEqual(asked, [.stereo(.max), .stereo(.high), .stereo(.medium)], "each refused rung is asked in order and nothing below the served one is")
		XCTAssertEqual(source?.url, served)
		XCTAssertEqual(source?.rung, .stereo(.medium), "the resolved source reports the served rung, not the requested one")
	}

	/// Only every rung refused resolves nothing; the whole ladder is asked first.
	func testEveryTierRefusedAsksTheWholeLadderAndResolvesNoSource() async throws {
		var asked: [HLSRung] = []

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: 981_563_422), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, rung in
				asked.append(rung)
				throw HLSStreamError.requestRefused(status: 403)
			},
			fetch: fileFetcher
		)

		XCTAssertEqual(asked, [.stereo(.max), .stereo(.high), .stereo(.medium), .stereo(.low)])
		XCTAssertNil(source, "only every rung being refused may resolve no source")
	}

	/// A stepped-down serve is cached under the tier that played and badged from it, so the
	/// player never claims 24-bit while the bytes are 16-bit.
	func testASteppedDownServeIsCachedAndBadgedAtTheServedTier() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let trackId = 981_563_423

		let playback = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, rung in
				if rung == .stereo(.max) { throw HLSStreamError.requestRefused(status: 403) }
				return local.multivariantURL
			},
			fetch: fileFetcher
		)

		let source = try XCTUnwrap(playback)
		XCTAssertEqual(source.rung, .stereo(.high), "Max refused, so Lossless is the served tier")
		XCTAssertEqual(HLSStreaming.badge(for: source.rung), "16-bit", "the badge reports what was served, not what was asked")
		let cached = await source.backgroundDownload?.value
		XCTAssertEqual(cached?.lastPathComponent, "\(trackId)-LOSSLESS.m4a", "the cache name carries the served tier")
	}

	/// A first play that stepped down is served from disk on the next play at the same tier,
	/// with no resolve and the same badge: both plays read what was served.
	func testACachedStepDownTierIsServedOnALaterPlayAtTheSameTier() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let trackId = 981_563_424

		let firstValue = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, rung in
				if rung == .stereo(.max) { throw HLSStreamError.requestRefused(status: 403) }
				return local.multivariantURL
			},
			fetch: fileFetcher
		)
		let first = try XCTUnwrap(firstValue)
		_ = await first.backgroundDownload?.value

		let secondValue = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in
				XCTFail("the cached stepped-down file must not resolve the manifest again")
				throw HLSStreamError.requestFailed
			},
			fetch: { url in
				XCTFail("a cached file must not fetch \(url)")
				throw HLSStreamError.requestFailed
			}
		)
		let second = try XCTUnwrap(secondValue)

		XCTAssertEqual(second.rung, .stereo(.high))
		XCTAssertEqual(second.url.lastPathComponent, "\(trackId)-LOSSLESS.m4a")
		XCTAssertEqual(
			HLSStreaming.badge(for: second.rung),
			HLSStreaming.badge(for: first.rung),
			"the streamed and the cached play must read the same served rung"
		)
	}

	/// A full ladder refusal resolves no HLS source, so the route walk carries on to the
	/// direct stream rather than ending the play. A stepped-down success does not, which is
	/// what keeps the track playable instead of greyed out.
	func testAnHLSRouteThatRefusesEveryTierStillFallsThroughToTheDirectStream() async throws {
		let direct = URL(fileURLWithPath: "/tmp/direct.flac")
		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: 981_563_425), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in throw HLSStreamError.requestRefused(status: 403) },
			fetch: fileFetcher
		)
		let resolver = PlaybackRouteResolver(
			hls: { source.map { PlayableStream(url: $0.url, quality: $0.rung.quality ?? .max, isDolbyAtmos: $0.rung.isDolbyAtmos, isHLS: true) } },
			directStream: { PlayableStream(url: direct, quality: .high, isDolbyAtmos: false) }
		)

		let resolved = await resolver.resolve(routes: [.hls, .directStream])

		XCTAssertEqual(resolved?.url, direct, "every rung refused must fall through, not fail the play")
	}

	/// A failed cache write is abandoned: the track still plays from the playlist, and
	/// nothing that looks cached is left behind.
	func testFailedBackgroundDownloadDoesNotBreakPlayback() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let trackId = 981_563_410

		let playback = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in local.multivariantURL },
			fetch: { url in
				if url.lastPathComponent == "seg-2.mp4" { throw HLSStreamError.fetchFailed(host: "cdn") }
				return try Data(contentsOf: url)
			}
		)

		let source = try XCTUnwrap(playback)
		XCTAssertEqual(source.url, local.multivariantURL, "the playlist must still play")
		let downloaded = await source.backgroundDownload?.value
		XCTAssertNil(downloaded, "a failed download caches nothing")
		XCTAssertFalse(
			FileManager.default.fileExists(atPath: PlaybackCache.fileURL(forTrackId: trackId, rung: .stereo(.max), in: directory).path)
		)
	}

	// MARK: - Prefetching

	/// The cache write behind a play prunes under the caller's protection, not with none: the
	/// current track, the prefetch window and the queue survive it. Without the protection the
	/// age sweep would delete the stale protected file.
	func testThePlayPathsCacheWritePrunesUnderTheCallersProtection() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let playingId = 981_563_419
		let protectingId = 981_563_420

		let protected = PlaybackCache.fileURL(forTrackId: protectingId, rung: .stereo(.max), in: directory)
		try validMP4Bytes().write(to: protected)
		try FileManager.default.setAttributes(
			[.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
			ofItemAtPath: protected.path
		)

		let playback = await HLSStreaming.playbackSource(
			for: makeTrack(id: playingId), session: makeSession(), quality: .max, cacheDirectory: directory,
			protecting: [protectingId], queueTrackIds: [protectingId],
			resolvePlaylist: { _, _ in local.multivariantURL }, fetch: fileFetcher
		)
		let download = try XCTUnwrap(playback?.backgroundDownload)
		_ = await download.value

		XCTAssertTrue(
			FileManager.default.fileExists(atPath: protected.path),
			"a protected track must survive the play path's own cache prune"
		)
	}

	/// The prefetcher prepares through the play path's own HLS cache write, so the next
	/// play is served from the cache with no resolve and no fetch.
	func testThePrefetcherPreparesHLSAndTheNextPlayReadsTheCache() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let upcomingId = 981_563_415
		var resolves = 0
		let prefetcher = PlaybackPrefetcher.make(
			for: makeSession(),
			qualityProvider: { .max },
			shouldPrepare: { _ in true },
			depthProvider: { 1 },
			cacheDirectory: directory,
			resolvePlaylist: { _, _ in
				resolves += 1
				return local.multivariantURL
			},
			fetch: fileFetcher
		)

		prefetcher.queueChanged(queue: [makeTrack(id: 981_563_414), makeTrack(id: upcomingId)], currentIndex: 0)
		await waitUntil { PlaybackCache.cachedFile(forTrackId: upcomingId, rung: .stereo(.max), in: directory) != nil }

		XCTAssertEqual(resolves, 1, "the prefetcher must resolve the upcoming track once")
		XCTAssertNotNil(PlaybackCache.cachedFile(forTrackId: upcomingId, rung: .stereo(.max), in: directory))

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: upcomingId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in
				XCTFail("a prepared track must not resolve a playlist on the next play")
				throw HLSStreamError.requestFailed
			},
			fetch: { url in
				XCTFail("a prepared track must not fetch \(url)")
				throw HLSStreamError.requestFailed
			}
		)

		XCTAssertEqual(
			source?.url,
			PlaybackCache.fileURL(forTrackId: upcomingId, rung: .stereo(.max), in: directory),
			"the next play must read the prepared cache file"
		)
		XCTAssertNil(source?.backgroundDownload, "the prepared file is complete, so nothing downloads behind the play")
	}

	/// A prefetch whose download fails leaves the track playable from the playlist.
	func testAFailedPrefetchLeavesTheTrackPlayableFromThePlaylist() async throws {
		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let trackId = 981_563_416

		let prepared = await HLSStreaming.playbackFile(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in local.multivariantURL },
			fetch: { url in
				if url.lastPathComponent == "seg-2.mp4" { throw HLSStreamError.fetchFailed(host: "cdn") }
				return try Data(contentsOf: url)
			}
		)

		XCTAssertNil(prepared, "a failed prefetch produces no file")
		XCTAssertNil(PlaybackCache.cachedFile(forTrackId: trackId, rung: .stereo(.max), in: directory))

		let source = await HLSStreaming.playbackSource(
			for: makeTrack(id: trackId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in local.multivariantURL }, fetch: fileFetcher
		)

		XCTAssertEqual(source?.url, local.multivariantURL, "a failed prefetch must not stop the track playing")
	}

	// MARK: - Badge

	/// A streamed track reads like a cached one once the player reports the rate the
	/// playlist could not carry: the badge is the tier's, and the rate is whichever source
	/// reported it.
	func testStreamedAndCachedBadgesMatchOnceTheRateIsKnown() async throws {
		let cachedId = 981_563_417
		try silentM4ABytes().write(to: PlaybackCache.fileURL(forTrackId: cachedId, rung: .stereo(.max), in: directory))
		let cached = await HLSStreaming.playbackSource(
			for: makeTrack(id: cachedId), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in
				XCTFail("a cached file must not resolve a playlist")
				throw HLSStreamError.requestFailed
			},
			fetch: { _ in
				XCTFail("a cached file must not fetch")
				throw HLSStreamError.requestFailed
			}
		)
		let cachedRate = try XCTUnwrap(cached?.sampleRate)

		let local = try makeLocalPlaylist(segments: ["AAAA", "BBBB"])
		let streamed = await HLSStreaming.playbackSource(
			for: makeTrack(id: 981_563_418), session: makeSession(), quality: .max, cacheDirectory: directory,
			resolvePlaylist: { _, _ in local.multivariantURL }, fetch: fileFetcher
		)
		XCTAssertNil(streamed?.sampleRate, "a playlist carries no format, so the player has to report it")

		for tier in [AudioQuality.max, .high, .medium, .low] {
			XCTAssertEqual(
				HLSStreaming.badge(for: tier, sampleRate: streamed?.sampleRate ?? cachedRate),
				HLSStreaming.badge(for: tier, sampleRate: cachedRate),
				"\(tier) must read the same streamed and cached"
			)
		}
	}

	/// The cache name carries the quality, so a Max file is never served at Lossless.
	func testHLSFileNamesDifferPerQuality() {
		XCTAssertNotEqual(
			PlaybackCache.fileURL(forTrackId: 1, rung: .stereo(.max), in: directory),
			PlaybackCache.fileURL(forTrackId: 1, rung: .stereo(.high), in: directory)
		)
	}

	/// A stub left by an interrupted download is deleted and reported as a miss.
	func testStubCachedFileIsDeletedAndTreatedAsAMiss() throws {
		let trackId = 981_563_407
		let stub = PlaybackCache.fileURL(forTrackId: trackId, rung: .stereo(.max), in: directory)
		try Data([0, 0, 0, 0x20]).write(to: stub)

		XCTAssertNil(PlaybackCache.cachedFile(forTrackId: trackId, rung: .stereo(.max), in: directory))
		XCTAssertFalse(FileManager.default.fileExists(atPath: stub.path), "the stub must be deleted")
	}

	/// The unbounded-growth guard: the prune enumerates its whole directory, so the new
	/// `.m4a` files are counted and can be evicted like the FLAC and DASH files.
	func testPruneCountsAndEvictsHLSFiles() throws {
		let now = Date()
		let hls = PlaybackCache.fileURL(forTrackId: 981_563_408, rung: .stereo(.max), in: directory)
		let bytes = validMP4Bytes()
		try bytes.write(to: hls)
		try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: hls.path)

		XCTAssertEqual(PlaybackCache.usageBytes(in: directory), bytes.count, "the usage must count the HLS file")

		let removed = PlaybackCache.prune(in: directory, maxBytes: 0, maxAge: .greatestFiniteMagnitude, now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), [hls.lastPathComponent])
		XCTAssertFalse(FileManager.default.fileExists(atPath: hls.path))
	}

	/// The same window exemption the other two shapes get applies to an HLS file inside
	/// the prefetch window.
	func testProtectedHLSFileSurvivesTheSizeCap() throws {
		let now = Date()
		let trackId = 981_563_409
		let hls = PlaybackCache.fileURL(forTrackId: trackId, rung: .stereo(.max), in: directory)
		try validMP4Bytes().write(to: hls)
		try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: hls.path)

		let removed = PlaybackCache.prune(
			in: directory, maxBytes: 0, maxAge: .greatestFiniteMagnitude,
			protecting: [trackId], now: now
		)

		XCTAssertTrue(removed.isEmpty)
		XCTAssertTrue(FileManager.default.fileExists(atPath: hls.path))
	}

	// MARK: - Format mapping

	func testEachRungRequestsExactlyOneUpperCasedFormat() {
		XCTAssertEqual(HLSRung.stereo(.max).format, "FLAC_HIRES")
		XCTAssertEqual(HLSRung.stereo(.high).format, "FLAC")
		XCTAssertEqual(HLSRung.stereo(.medium).format, "AACLC")
		XCTAssertEqual(HLSRung.stereo(.low).format, "HEAACV1")
		XCTAssertEqual(HLSRung.dolbyAtmos.format, "EAC3_JOC")
	}

	/// The ladder starts at the chosen tier and ends at the lowest one, never above the
	/// chosen tier.
	func testEachQualityWalksDownToTheLowestTier() {
		XCTAssertEqual(HLSStreaming.qualityLadder(for: .max), [.max, .high, .medium, .low])
		XCTAssertEqual(HLSStreaming.qualityLadder(for: .high), [.high, .medium, .low])
		XCTAssertEqual(HLSStreaming.qualityLadder(for: .medium), [.medium, .low])
		XCTAssertEqual(HLSStreaming.qualityLadder(for: .low), [.low])
	}

	// MARK: - Badge

	/// Tidal's fMP4 FLAC reports no bit depth, so the badge reads the served tier; the
	/// sample rate appears only when the stream reported one.
	func testBadgeForEachTier() {
		XCTAssertEqual(HLSStreaming.badge(for: .max), "24-bit")
		XCTAssertEqual(HLSStreaming.badge(for: .max, sampleRate: 44_100), "24-bit 44.1kHz")
		XCTAssertEqual(HLSStreaming.badge(for: .high), "16-bit")
		XCTAssertEqual(HLSStreaming.badge(for: .high, sampleRate: 44_100), "16-bit 44.1kHz")
		XCTAssertEqual(HLSStreaming.badge(for: .medium), "320 kbps")
		XCTAssertEqual(HLSStreaming.badge(for: .low), "96 kbps")
	}

	// MARK: - Helpers

	private func parse(_ text: String) throws -> HLSPlaylist {
		try HLSPlaylistParser.parse(text, baseURL: URL(string: "https://im-fa.manifest.tidal.com/master.m3u8")!)
	}

	private struct LocalPlaylist {
		let multivariantURL: URL
		let initBytes: Data
	}

	/// An fMP4 init segment begins with the `ftyp` box; the rest is padding so the
	/// concatenated file clears the completeness check.
	private func validMP4Bytes() -> Data {
		Data([0, 0, 0, 0x20]) + Data("ftyp".utf8) + Data(repeating: 0xAA, count: 512)
	}

	/// A real AAC-in-MP4 file, which `sampleRate(of:)` reads like a cached HLS file.
	private func silentM4ABytes() throws -> Data {
		try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "m4a", subdirectory: "Fixtures")))
	}

	/// Without a fixed sleep that would make the test flaky.
	private func waitUntil(timeout: TimeInterval = 1.0, _ condition: () -> Bool) async {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return }
			try? await Task.sleep(for: .milliseconds(5))
		}
	}

	/// A local stand-in for Tidal's CDN: a master playlist, a variant playlist, an init
	/// segment and the media segments, all written as real files so relative URIs resolve
	/// exactly as they do over HTTPS.
	private func makeLocalPlaylist(
		segments: [String],
		initBytes: Data? = nil,
		topLevelIsMediaPlaylist: Bool = false
	) throws -> LocalPlaylist {
		let root = directory.appendingPathComponent("cdn-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let initBytes = initBytes ?? validMP4Bytes()
		try initBytes.write(to: root.appendingPathComponent("init.mp4"))
		for (index, segment) in segments.enumerated() {
			try Data(segment.utf8).write(to: root.appendingPathComponent("seg-\(index + 1).mp4"))
		}
		let mediaPlaylist = (["#EXTM3U", "#EXT-X-TARGETDURATION:4", "#EXT-X-MAP:URI=\"init.mp4\""]
			+ segments.indices.flatMap { ["#EXTINF:4.000,", "seg-\($0 + 1).mp4"] }
			+ ["#EXT-X-ENDLIST"]).joined(separator: "\n")
		let topLevel = topLevelIsMediaPlaylist
			? mediaPlaylist
			: ["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=1596037,CODECS=\"fLaC\"", "variant.m3u8"].joined(separator: "\n")
		if !topLevelIsMediaPlaylist {
			try Data(mediaPlaylist.utf8).write(to: root.appendingPathComponent("variant.m3u8"))
		}
		let multivariantURL = root.appendingPathComponent("master.m3u8")
		try Data(topLevel.utf8).write(to: multivariantURL)
		return LocalPlaylist(multivariantURL: multivariantURL, initBytes: initBytes)
	}

	private var fileFetcher: HLSStreaming.ResourceFetcher {
		{ url in try Data(contentsOf: url) }
	}

	private func makeSession() -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: .max
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
}
