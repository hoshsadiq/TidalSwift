//
//  HiResStreamingPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the route policy: which path is tried, and in what order. Tidal's desktop route leads
/// at every tier with the direct-stream path as its fallback; only the Atmos preference picks
/// the direct-stream path, because Atmos is served there and nowhere else.
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

	/// The decrypted FLAC prevails at Max and Lossless, the assembled DASH at High and Low.
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

	func testMaxStartsWithTheDesktopRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: .max
			),
			[.hiResStereo, .directStream]
		)
	}

	/// The decrypted 16-bit rendition is prepared into the cache, which keeps it instant.
	func testLosslessStereoStartsWithTheDesktopRoute() {
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
			trackHasStereo: true, trackHasDolbyAtmos: false, quality: .high
		)
		XCTAssertEqual(routes.first, .hiResStereo)
		XCTAssertEqual(routes, [.hiResStereo, .directStream])
	}

	func testLosslessDualFormatTrackStartsWithTheDesktopRoute() {
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
			trackHasStereo: true, trackHasDolbyAtmos: true, quality: .high
		)
		XCTAssertEqual(routes.first, .hiResStereo)
		XCTAssertEqual(routes, [.hiResStereo, .directStream])
	}

	func testLosslessDualFormatTrackPrefersAtmosWhenAsked() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: true,
				trackHasStereo: true, trackHasDolbyAtmos: true, quality: .high
			),
			[.directStream]
		)
	}

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

	/// Tidal's route needs the capability and a stereo rendition; either missing keeps the
	/// direct-stream path alone.
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

	/// The assembled AAC is a stereo rendition, so the extra Atmos mode does not change it.
	func testDashRouteLeadsForADualFormatTrackWithoutTheAtmosPreference() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: true, quality: .medium
			),
			[.dash, .directStream]
		)
	}

	func testWithoutCapabilityOnlyTheDirectStreamRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: false, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: .max
			),
			[.directStream]
		)
	}

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

	func testDashRouteIsResolvedToItsLocalFile() async {
		let local = URL(fileURLWithPath: "/tmp/dash.aac.m4a")
		var directStreamAsked = false
		let resolver = PlaybackRouteResolver(
			hiResStereo: { nil },
			dash: { PlayableStream(url: local, quality: .medium, isDolbyAtmos: false, isHiResStereo: false, hiResBitDepth: nil, hiResSampleRate: nil) },
			directStream: { directStreamAsked = true; return nil }
		)

		let resolved = await resolver.resolve(routes: [.dash, .directStream])

		XCTAssertEqual(resolved?.url, local)
		XCTAssertEqual(resolved?.quality, .medium)
		XCTAssertFalse(directStreamAsked, "a resolved route must stop the walk")
	}

	func testFailedDashFallsThroughToTheDirectStreamRoute() async {
		let direct = URL(fileURLWithPath: "/tmp/direct.flac")
		let resolver = PlaybackRouteResolver(
			hiResStereo: { nil },
			dash: { nil },
			directStream: { PlayableStream(url: direct, quality: .medium, isDolbyAtmos: false, isHiResStereo: false, hiResBitDepth: nil, hiResSampleRate: nil) }
		)

		let resolved = await resolver.resolve(routes: [.dash, .directStream])

		XCTAssertEqual(resolved?.url, direct)
	}

	func testAllRoutesFailingResolvesNothing() async {
		let resolver = PlaybackRouteResolver(hiResStereo: { nil }, dash: { nil }, directStream: { nil })
		let resolved = await resolver.resolve(routes: [.dash, .directStream])
		XCTAssertNil(resolved)
	}
}
