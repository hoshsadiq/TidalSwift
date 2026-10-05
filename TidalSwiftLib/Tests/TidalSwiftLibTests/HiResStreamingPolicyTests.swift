//
//  HiResStreamingPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the hi-res route policy: which path is tried, and in what order. The rule is
/// capability × preference × Atmos preference × track capabilities × quality, so
/// every combination is asserted rather than a representative few.
@MainActor
final class HiResStreamingPolicyTests: XCTestCase {
	/// The rule, restated independently of the implementation, so a change to either
	/// side that the other does not follow fails here.
	private func expected(
		capable: Bool,
		enabled: Bool,
		preferAtmos: Bool,
		hasStereo: Bool,
		hasAtmos: Bool,
		quality: AudioQuality
	) -> [HiResStreamingRoute] {
		if preferAtmos && hasAtmos {
			return [.standard]
		}
		guard capable, enabled, hasStereo else {
			return [.standard]
		}
		switch quality {
		case .max:
			return [.hiResStereo, .standard]
		case .high:
			// Mirrors the policy: a dual-format track gets no stereo from the standard
			// route at this tier, so the rescue leads for it and only for it.
			return hasAtmos ? [.hiResStereo, .standard] : [.standard, .hiResStereo]
		case .medium, .low:
			return [.standard]
		}
	}

	/// Every combination of the inputs, asserting both the route order and which route
	/// plays first.
	func testEveryCombinationProducesTheExpectedRouteOrder() {
		for capable in [true, false] {
			for enabled in [true, false] {
				for preferAtmos in [true, false] {
					for hasStereo in [true, false] {
						for hasAtmos in [true, false] {
							for quality in [AudioQuality.low, .medium, .high, .max] {
								let expectedRoutes = expected(
									capable: capable,
									enabled: enabled,
									preferAtmos: preferAtmos,
									hasStereo: hasStereo,
									hasAtmos: hasAtmos,
									quality: quality
								)
								let label = "capable=\(capable) enabled=\(enabled) preferAtmos=\(preferAtmos) stereo=\(hasStereo) atmos=\(hasAtmos) quality=\(quality)"
								XCTAssertEqual(
									HiResStreamingPolicy.routes(
										sessionHasHiResStereoAccess: capable,
										enabled: enabled,
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
										enabled: enabled,
										preferDolbyAtmos: preferAtmos,
										trackHasStereo: hasStereo,
										trackHasDolbyAtmos: hasAtmos,
										quality: quality
									),
									expectedRoutes.first == .hiResStereo,
									label
								)
							}
						}
					}
				}
			}
		}
	}

	/// Max: the desktop rendition is the only way to 24-bit, so it is tried first with
	/// today's path as the fallback.
	func testMaxStartsWithTheDesktopRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, enabled: true, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: .max
			),
			[.hiResStereo, .standard]
		)
	}

	/// The reported bug: with the toggle on and Lossless selected, a stereo track must
	/// not go through the desktop route first — the standard route serves the same
	/// 16-bit file, instantly and unencrypted, with the desktop route behind it as the
	/// rescue for tracks the standard route refuses.
	func testLosslessStereoDoesNotStartWithTheDesktopRoute() {
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: true, enabled: true, preferDolbyAtmos: false,
			trackHasStereo: true, trackHasDolbyAtmos: false, quality: .high
		)
		XCTAssertEqual(routes.first, .standard)
		XCTAssertEqual(routes, [.standard, .hiResStereo])
	}

	/// A dual-format track is the exception at Lossless: the standard route cannot give
	/// it stereo at that tier (the stream is refused and the manifest answers with the
	/// Atmos rendition), so the rescue leads and the track is downloaded.
	func testLosslessDualFormatTrackStartsWithTheDesktopRoute() {
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: true, enabled: true, preferDolbyAtmos: false,
			trackHasStereo: true, trackHasDolbyAtmos: true, quality: .high
		)
		XCTAssertEqual(routes.first, .hiResStereo)
		XCTAssertEqual(routes, [.hiResStereo, .standard])
	}

	/// …and the Atmos preference still overrules that, because it is an explicit choice.
	func testLosslessDualFormatTrackPrefersAtmosWhenAsked() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, enabled: true, preferDolbyAtmos: true,
				trackHasStereo: true, trackHasDolbyAtmos: true, quality: .high
			),
			[.standard]
		)
	}

	/// The Atmos preference wins outright, and it is served by the standard route.
	func testAtmosPreferenceWinsEvenAtMax() {
		for quality in [AudioQuality.low, .medium, .high, .max] {
			XCTAssertEqual(
				HiResStreamingPolicy.routes(
					sessionHasHiResStereoAccess: true, enabled: true, preferDolbyAtmos: true,
					trackHasStereo: true, trackHasDolbyAtmos: true, quality: quality
				),
				[.standard],
				"quality=\(quality)"
			)
		}
	}

	/// Below Lossless there is no FLAC to fetch, so the standard route is the whole
	/// answer and the fallback chain is left to the lane that builds the DASH path.
	func testBelowLosslessNeverUsesTheDesktopRoute() {
		for quality in [AudioQuality.low, .medium] {
			XCTAssertEqual(
				HiResStreamingPolicy.routes(
					sessionHasHiResStereoAccess: true, enabled: true, preferDolbyAtmos: false,
					trackHasStereo: true, trackHasDolbyAtmos: false, quality: quality
				),
				[.standard],
				"quality=\(quality)"
			)
		}
	}

	/// A session without the capability, or the preference switched off, behaves as
	/// before: the standard route only.
	func testWithoutCapabilityOrPreferenceOnlyTheStandardRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: false, enabled: true, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: .max
			),
			[.standard]
		)
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, enabled: false, preferDolbyAtmos: false,
				trackHasStereo: true, trackHasDolbyAtmos: false, quality: .max
			),
			[.standard]
		)
	}

	/// An Atmos-only track has no stereo rendition, so the desktop route can never be
	/// the first choice.
	func testAtmosOnlyTrackNeverStartsWithTheDesktopRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(
				sessionHasHiResStereoAccess: true, enabled: true, preferDolbyAtmos: false,
				trackHasStereo: false, trackHasDolbyAtmos: true, quality: .max
			),
			[.standard]
		)
	}
}
