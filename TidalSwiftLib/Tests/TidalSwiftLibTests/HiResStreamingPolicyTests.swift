//
//  HiResStreamingPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the hi-res route policy: which path is tried, and in what order. The rule
/// is capability × preference × track, so every combination is asserted rather than
/// a representative few.
@MainActor
final class HiResStreamingPolicyTests: XCTestCase {
	/// The only case that changes behaviour: a capable session, the preference on and
	/// a track with a stereo rendition. Everything else keeps today's path exactly.
	func testEveryCapabilityPreferenceTrackCombination() {
		for capable in [true, false] {
			for enabled in [true, false] {
				for stereo in [true, false] {
					let expected: [HiResStreamingRoute] = (capable && enabled && stereo)
						? [.hiResStereo, .standard]
						: [.standard]
					let label = "capable=\(capable) enabled=\(enabled) stereo=\(stereo)"
					XCTAssertEqual(
						HiResStreamingPolicy.routes(sessionHasHiResStereoAccess: capable, enabled: enabled, trackHasStereo: stereo),
						expected,
						label
					)
					XCTAssertEqual(
						HiResStreamingPolicy.usesHiResStereo(sessionHasHiResStereoAccess: capable, enabled: enabled, trackHasStereo: stereo),
						expected.first == .hiResStereo,
						label
					)
				}
			}
		}
	}

	/// The fallback order is the point, not just the first choice: today's path is
	/// always the second entry, so a track the hi-res route cannot serve still plays.
	func testStandardIsAlwaysTheFallback() {
		let routes = HiResStreamingPolicy.routes(sessionHasHiResStereoAccess: true, enabled: true, trackHasStereo: true)
		XCTAssertEqual(routes, [.hiResStereo, .standard])
		XCTAssertEqual(routes.last, .standard)
	}

	func testAtmosOnlyTrackNeverTakesTheStereoRoute() {
		XCTAssertEqual(
			HiResStreamingPolicy.routes(sessionHasHiResStereoAccess: true, enabled: true, trackHasStereo: false),
			[.standard]
		)
	}
}
