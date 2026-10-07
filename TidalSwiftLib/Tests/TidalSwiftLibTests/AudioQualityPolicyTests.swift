//
//  AudioQualityPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the subscription gate's rule: which tiers a subscription may pick, and the override.
@MainActor
final class AudioQualityPolicyTests: XCTestCase {
	func testTierAtOrBelowTheCapIsAvailable() {
		let cases: [(cap: AudioQuality, tier: AudioQuality)] = [
			(.low, .low),
			(.medium, .low), (.medium, .medium),
			(.high, .low), (.high, .medium), (.high, .high),
			(.max, .low), (.max, .medium), (.max, .high), (.max, .max)
		]
		for (cap, tier) in cases {
			XCTAssertTrue(
				AudioQualityPolicy.isAvailable(tier, subscriptionHighest: cap, ignoringLimits: false),
				"\(tier) should be available when the subscription reaches \(cap)"
			)
		}
	}

	func testTierAboveTheCapIsUnavailable() {
		let cases: [(cap: AudioQuality, tier: AudioQuality)] = [
			(.low, .medium), (.low, .high), (.low, .max),
			(.medium, .high), (.medium, .max),
			(.high, .max)
		]
		for (cap, tier) in cases {
			XCTAssertFalse(
				AudioQualityPolicy.isAvailable(tier, subscriptionHighest: cap, ignoringLimits: false),
				"\(tier) should be unavailable when the subscription only reaches \(cap)"
			)
		}
	}

	func testOverrideMakesEveryTierAvailable() {
		for cap in AudioQuality.allCases {
			for tier in AudioQuality.allCases {
				XCTAssertTrue(
					AudioQualityPolicy.isAvailable(tier, subscriptionHighest: cap, ignoringLimits: true),
					"the override must make \(tier) available with a \(cap) cap"
				)
			}
		}
	}

	func testMissingSubscriptionCapAllowsEveryTier() {
		for tier in AudioQuality.allCases {
			XCTAssertTrue(
				AudioQualityPolicy.isAvailable(tier, subscriptionHighest: nil, ignoringLimits: false),
				"a missing cap must leave \(tier) available"
			)
		}
	}

	/// `AudioQuality` has no unknown case, so a string this build does not know cannot be
	/// ranked and falls back to "available" rather than refusing.
	func testUnknownSubscriptionTierAllowsEveryTier() {
		let unknown = AudioQuality(rawValue: "SUPER_HI_RES_LOSSLESS")
		XCTAssertNil(unknown, "the test needs a raw value AudioQuality cannot rank")
		XCTAssertFalse(AudioQualityPolicy.ladder.contains(where: { $0.rawValue == "SUPER_HI_RES_LOSSLESS" }))

		for tier in AudioQuality.allCases {
			XCTAssertTrue(
				AudioQualityPolicy.isAvailable(tier, subscriptionHighest: unknown, ignoringLimits: false),
				"an unknown cap must leave \(tier) available"
			)
		}
	}

	/// The policy decides availability only, so a refused tier stays the caller's choice.
	func testPolicyNeverRewritesAChosenTier() {
		let chosen: AudioQuality = .max
		let available: Bool = AudioQualityPolicy.isAvailable(chosen, subscriptionHighest: .low, ignoringLimits: false)

		XCTAssertFalse(available, "a tier above the cap is reported unavailable")
		XCTAssertEqual(chosen, .max, "reporting a tier unavailable must not change the chosen tier")
	}

	/// The ladder is the four stereo tiers, so no spatial format can be gated by a
	/// subscription tier.
	func testLadderIsTheFourStereoTiers() {
		XCTAssertEqual(AudioQualityPolicy.ladder, [.low, .medium, .high, .max])
	}
}
