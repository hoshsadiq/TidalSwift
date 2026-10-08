//
//  PlaybackRoutingPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the route policy: which path is tried, and in what order. Tidal's HLS manifest leads
/// whenever the session has desktop playback access, whatever the advertised modes and the
/// Atmos preference say; the direct-stream path is the fallback. The preference only reorders
/// the HLS rungs (`HLSStreaming.rungs`), it never removes the route.
@MainActor
final class PlaybackRoutingPolicyTests: XCTestCase {
	/// Restated independently of the implementation, so a change to either side that the other
	/// does not follow fails here.
	private func expected(capable: Bool) -> [PlaybackRoute] {
		capable ? [.hls, .directStream] : [.directStream]
	}

	/// For every combination of (desktop access, preference, advertised modes) the route list
	/// is desktop-driven — the preference and the modes never remove HLS — while the HLS rung
	/// ladder is preference-driven. Two decisions, pinned together over the whole matrix.
	func testEveryCombinationProducesTheExpectedRouteOrder() {
		for capable in [true, false] {
			for preferAtmos in [true, false] {
				for hasStereo in [true, false] {
					for hasAtmos in [true, false] {
						let label = "capable=\(capable) preferAtmos=\(preferAtmos) stereo=\(hasStereo) atmos=\(hasAtmos)"
						let expectedRoutes = expected(capable: capable)
						XCTAssertEqual(
							PlaybackRoutingPolicy.routes(sessionHasDesktopPlaybackAccess: capable),
							expectedRoutes,
							label
						)
						XCTAssertEqual(
							PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: capable),
							expectedRoutes.first == .hls,
							label
						)
						let rungs = HLSStreaming.rungs(for: .high, preferDolbyAtmos: preferAtmos, trackHasDolbyAtmos: hasAtmos)
						XCTAssertEqual(
							rungs.first?.isDolbyAtmos ?? false,
							preferAtmos && hasAtmos,
							"the Atmos preference puts the Atmos rung first: \(label)"
						)
						XCTAssertEqual(
							rungs.contains(.dolbyAtmos),
							hasAtmos,
							"only an Atmos-advertised track gets the Atmos rung: \(label)"
						)
					}
				}
			}
		}
	}

	/// HLS leads, and the direct stream is always the last fallback.
	func testEveryCapableTrackLeadsWithHLSAndEndsWithTheDirectStream() {
		for capable in [true, false] {
			let routes = PlaybackRoutingPolicy.routes(sessionHasDesktopPlaybackAccess: capable)
			XCTAssertEqual(routes.first, capable ? .hls : .directStream)
			XCTAssertEqual(routes.last, .directStream, "the direct stream is always the fallback")
		}
	}

	/// The desktop `cuk` claim is the only gate on Tidal's route; a missing stereo rendition no
	/// longer drops it, because the catalogue omits STEREO for tracks the manifest serves.
	func testTidalsRouteNeedsOnlyTheDesktopSession() {
		XCTAssertEqual(
			PlaybackRoutingPolicy.routes(sessionHasDesktopPlaybackAccess: false),
			[.directStream],
			"no desktop session"
		)
		XCTAssertFalse(PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: false))
		XCTAssertEqual(
			PlaybackRoutingPolicy.routes(sessionHasDesktopPlaybackAccess: true),
			[.hls, .directStream],
			"an Atmos-only track still gets the HLS route"
		)
		XCTAssertTrue(PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: true))
	}

	// MARK: - Resolver

	/// HLS leads: a resolved playlist stops the walk before the direct stream runs.
	func testHLSRouteResolvesToItsPlaylistAndStopsTheWalk() async {
		let playlist = URL(string: "https://im-fa.manifest.tidal.com/master.m3u8")!
		var directStreamAsked = false
		let resolver = PlaybackRouteResolver(
			hls: { PlayableStream(url: playlist, quality: .max, isDolbyAtmos: false, isHLS: true) },
			directStream: { directStreamAsked = true; return nil }
		)

		let resolved = await resolver.resolve(routes: [.hls, .directStream])

		XCTAssertEqual(resolved?.url, playlist)
		XCTAssertTrue(resolved?.isHLS ?? false)
		XCTAssertFalse(directStreamAsked, "a resolved route must stop the walk")
	}

	/// A manifest Tidal refuses must fall through to the direct stream, not end the play.
	func testRefusedHLSFallsThroughToTheDirectStreamRoute() async {
		let direct = URL(fileURLWithPath: "/tmp/direct.flac")
		let resolver = PlaybackRouteResolver(
			hls: { nil },
			directStream: { PlayableStream(url: direct, quality: .high, isDolbyAtmos: false) }
		)

		let resolved = await resolver.resolve(routes: [.hls, .directStream])

		XCTAssertEqual(resolved?.url, direct)
		XCTAssertFalse(resolved?.isHLS ?? true)
	}

	func testAllRoutesFailingResolvesNothing() async {
		let resolver = PlaybackRouteResolver(hls: { nil }, directStream: { nil })
		let resolved = await resolver.resolve(routes: [.hls, .directStream])
		XCTAssertNil(resolved)
	}
}
