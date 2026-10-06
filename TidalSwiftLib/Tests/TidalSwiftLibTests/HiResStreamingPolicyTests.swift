//
//  HiResStreamingPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the route policy: which path is tried, and in what order. The rule is
/// capability × preference × Atmos preference × track capabilities × quality, so
/// every combination is asserted rather than a representative few.
///
/// Tidal's own desktop route leads at every tier; the direct-stream path is the
/// fallback it falls through to. Only the Atmos preference deliberately chooses the
/// direct-stream path, because Atmos is served there and nowhere else.
@MainActor
final class HiResStreamingPolicyTests: XCTestCase {
	/// The rule, restated independently of the implementation, so a change to either
	/// side that the other does not follow fails here.
	private func expected(
		capable: Bool,
		preferAtmos: Bool,
		hasStereo: Bool,
		hasAtmos: Bool,
		quality: AudioQuality
	) -> [HiResStreamingRoute] {
		if preferAtmos && hasAtmos {
			return [.directStream]
		}
		guard capable, hasStereo else {
			return [.directStream]
		}
		switch quality {
		case .max, .high:
			return [.hiResStereo, .directStream]
		case .medium, .low:
			return [.dash, .directStream]
		}
	}

	/// Every combination of the inputs, asserting both the route order and which route
	/// plays first.
	func testEveryCombinationProducesTheExpectedRouteOrder() {
		for capable in [true, false] {
				for preferAtmos in [true, false] {
					for hasStereo in [true, false] {
						for hasAtmos in [true, false] {
							for quality in [AudioQuality.low, .medium, .high, .max] {
								let expectedRoutes = expected(
									capable: capable,
									preferAtmos: preferAtmos,
									hasStereo: hasStereo,
									hasAtmos: hasAtmos,
									quality: quality
								)
								let label = "capable=\(capable) preferAtmos=\(preferAtmos) stereo=\(hasStereo) atmos=\(hasAtmos) quality=\(quality)"
								XCTAssertEqual(
									HiResStreamingPolicy.routes(
										sessionHasHiResStereoAccess: capable,
										preferDolbyAtmos: preferAtmos,
										trackHasStereo: hasStereo,
										trackHasDolbyAtmos: hasAtmos,
										quality: quality
									),
									expectedRoutes,
									label
								)
								XCTAssertEqual(
									HiResStreamingPolicy.usesHiResStereo(
										sessionHasHiResStereoAccess: capable,
										preferDolbyAtmos: preferAtmos,
										trackHasStereo: hasStereo,
										trackHasDolbyAtmos: hasAtmos,
										quality: quality
									),
									expectedRoutes.first == .hiResStereo,
									label
								)
								XCTAssertEqual(
									HiResStreamingPolicy.usesLocalFile(
										sessionHasHiResStereoAccess: capable,
										preferDolbyAtmos: preferAtmos,
										trackHasStereo: hasStereo,
										trackHasDolbyAtmos: hasAtmos,
										quality: quality
									),
									expectedRoutes.first == .hiResStereo || expectedRoutes.first == .dash,
									label
								)
							}
						}
					}
				}
			}
		}

	/// Tidal's route leads at every tier when the session can use it: the decrypted
	/// FLAC rendition at Max and Lossless, the assembled DASH file at High and Low.
	func testEveryTierStartsWithTidalsRoute() {
		for quality in [AudioQuality.low, .medium, .high, .max] {
			let routes = HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: quality
			)
			XCTAssertEqual(routes.last, .directStream, "the direct stream is always the fallback")
			XCTAssertNotEqual(routes.first, .directStream, "quality=\(quality)")
		}
	}

	/// Max: the decrypted FLAC rendition is the only way to 24-bit, so it leads with
	/// the direct-stream path as the fallback.
	func testMaxStartsWithTheDesktopRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: .max
			),
			[.hiResStereo, .directStream]
		)
	}

	/// Lossless also leads with Tidal's route: the decrypted 16-bit rendition is
	/// prepared into the cache, which is what keeps it instant. The direct-stream path
	/// is only the fallback.
	func testLosslessStereoStartsWithTheDesktopRoute() {
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
			trackHasStereo: true, trackHasDolbyAtmos: false, quality: .high
		)
		XCTAssertEqual(routes.first, .hiResStereo)
		XCTAssertEqual(routes, [.hiResStereo, .directStream])
	}

	/// A dual-format track behaves the same at Lossless: Tidal's route leads, the
	/// direct stream falls back.
	func testLosslessDualFormatTrackStartsWithTheDesktopRoute() {
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
			trackHasStereo: true, trackHasDolbyAtmos: true, quality: .high
		)
		XCTAssertEqual(routes.first, .hiResStereo)
		XCTAssertEqual(routes, [.hiResStereo, .directStream])
	}

	/// …and the Atmos preference overrules that, because Atmos is only served by the
	/// direct-stream path.
	func testLosslessDualFormatTrackPrefersAtmosWhenAsked() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: true,
				trackHasStereo: true, trackHasDolbyAtmos: true, quality: .high
			),
			[.directStream]
		)
	}

	/// The Atmos preference wins outright, and it is served by the direct-stream route.
	func testAtmosPreferenceWinsEvenAtMax() {
		for quality in [AudioQuality.low, .medium, .high, .max] {
			XCTAssertEqual(
				HiResStreamingPolicy.routes(
					sessionHasHiResStereoAccess: true, preferDolbyAtmos: true,
					trackHasStereo: true, trackHasDolbyAtmos: true, quality: quality
				),
				[.directStream],
				"quality=\(quality)"
			)
		}
	}

	/// Below Lossless the assembled AAC file leads; the direct stream falls back.
	func testBelowLosslessStartsWithTheDashRoute() {
		for quality in [AudioQuality.low, .medium] {
			XCTAssertEqual(
				HiResStreamingPolicy.routes(
					sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
					trackHasStereo: true, trackHasDolbyAtmos: false, quality: quality
				),
				[.dash, .directStream],
				"quality=\(quality)"
			)
		}
	}

	/// Tidal's route needs the capability and a stereo rendition. Either missing keeps
	/// the direct-stream path alone, so a session that cannot use Tidal's route never
	/// tries it.
	func testTidalsRouteNeedsCapabilityAndStereo() {
		for quality in [AudioQuality.low, .medium, .high, .max] {
			XCTAssertEqual(
				HiResStreamingPolicy.routes(
					sessionHasHiResStereoAccess: false, preferDolbyAtmos: false,
					trackHasStereo: true, trackHasDolbyAtmos: false, quality: quality
				),
				[.directStream],
				"no capability, quality=\(quality)"
			)
			XCTAssertEqual(
				HiResStreamingPolicy.routes(
					sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
					trackHasStereo: false, trackHasDolbyAtmos: true, quality: quality
				),
				[.directStream],
				"no stereo, quality=\(quality)"
			)
		}
	}

	/// A dual-format track at High/Low still leads with DASH when the Atmos preference
	/// is off: the assembled AAC is a stereo rendition, so the extra Atmos mode does
	/// not change the order.
	func testDashRouteLeadsForADualFormatTrackWithoutTheAtmosPreference() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: true, quality: .medium
			),
			[.dash, .directStream]
		)
	}

	/// A session without the capability keeps the direct-stream path only. The quality
	/// selection is the only switch left: there is no separate toggle.
	func testWithoutCapabilityOnlyTheDirectStreamRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: false, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: .max
			),
			[.directStream]
		)
	}

	/// An Atmos-only track has no stereo rendition, so Tidal's route can never be the
	/// first choice.
	func testAtmosOnlyTrackNeverStartsWithTidalsRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
				trackHasStereo: false, trackHasDolbyAtmos: true, quality: .max
			),
			[.directStream]
		)
	}

	// MARK: - Resolver

	/// Given a `.dash` producer that yields a file, the resolver returns it and stops —
	/// the direct-stream route is never asked.
	func testDashRouteIsResolvedToItsLocalFile() async {
		let local = URL(fileURLWithPath: "/tmp/dash.aac.m4a")
		var directStreamAsked = false
		let resolver = PlaybackRouteResolver(
			hiResStereo: { nil },
			dash: { PlayableStream(url: local, quality: .medium, isDolbyAtmos: false, isHiResStereo: false, hiResBitDepth: nil) },
			directStream: { directStreamAsked = true; return nil }
		)

		let resolved = await resolver.resolve(routes: [.dash, .directStream])

		XCTAssertEqual(resolved?.url, local)
		XCTAssertEqual(resolved?.quality, .medium)
		XCTAssertFalse(directStreamAsked, "a resolved route must stop the walk")
	}

	/// Given a `.dash` producer that fails, the resolver falls through to the
	/// direct-stream route exactly as it does for the hi-res route.
	func testFailedDashFallsThroughToTheDirectStreamRoute() async {
		let direct = URL(fileURLWithPath: "/tmp/direct.flac")
		let resolver = PlaybackRouteResolver(
			hiResStereo: { nil },
			dash: { nil },
			directStream: { PlayableStream(url: direct, quality: .medium, isDolbyAtmos: false, isHiResStereo: false, hiResBitDepth: nil) }
		)

		let resolved = await resolver.resolve(routes: [.dash, .directStream])

		XCTAssertEqual(resolved?.url, direct)
	}

	/// Every route failing leaves no stream, so the caller skips the track.
	func testAllRoutesFailingResolvesNothing() async {
		let resolver = PlaybackRouteResolver(hiResStereo: { nil }, dash: { nil }, directStream: { nil })
		let resolved = await resolver.resolve(routes: [.dash, .directStream])
		XCTAssertNil(resolved)
	}
}
