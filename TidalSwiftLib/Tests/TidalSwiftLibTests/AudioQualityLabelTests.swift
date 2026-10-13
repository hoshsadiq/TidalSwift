//
//  AudioQualityLabelTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 13.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Pins the one vocabulary both quality pickers read. These assertions fail if a second
/// vocabulary comes back: a tier dropped from the labels, "High" claimed by two tiers, or
/// "HiFi" reappearing.
final class AudioQualityLabelTests: XCTestCase {
	@MainActor
	func testEveryTierHasANameAndDetail() {
		for quality in AudioQuality.allCases {
			XCTAssertFalse(quality.label.name.isEmpty, "\(quality) has no name")
			XCTAssertFalse(quality.label.detail.isEmpty, "\(quality) has no detail")
		}
	}

	/// The only name two tiers may share is "Low", and only for the two lossy tiers.
	@MainActor
	func testNoTwoTiersShareAName() {
		for first in AudioQuality.allCases {
			for second in AudioQuality.allCases where second != first {
				guard first.label.name == second.label.name else { continue }
				XCTAssertNotNil(first.label.bitrate, "\(first) and \(second) share a name without a bitrate")
				XCTAssertNotNil(second.label.bitrate, "\(first) and \(second) share a name without a bitrate")
			}
		}
	}

	@MainActor
	func testNamesCoverOnlyLowHighAndMax() {
		let names = Set(AudioQuality.allCases.map(\.label.name))
		XCTAssertEqual(names, ["Low", "High", "Max"])
	}

	@MainActor
	func testHighIsNeverNamedHiFi() {
		XCTAssertNotEqual(AudioQuality.high.label.name, "HiFi")
		XCTAssertFalse(AudioQuality.allCases.contains { $0.label.name == "HiFi" })
	}

	@MainActor
	func testMediumIsNotNamedHigh() {
		XCTAssertNotEqual(AudioQuality.medium.label.name, "High")
	}

	@MainActor
	func testLossyTiersAreBothLowWithTheirBitrates() {
		XCTAssertEqual(AudioQuality.low.label.name, "Low")
		XCTAssertEqual(AudioQuality.low.label.optionLabel, "96 kbps")
		XCTAssertEqual(AudioQuality.medium.label.name, "Low")
		XCTAssertEqual(AudioQuality.medium.label.optionLabel, "320 kbps")
	}

	@MainActor
	func testLosslessTiersCarryNoBitrate() {
		XCTAssertNil(AudioQuality.high.label.bitrate)
		XCTAssertNil(AudioQuality.max.label.bitrate)
		XCTAssertEqual(AudioQuality.high.label.optionLabel, "High")
		XCTAssertEqual(AudioQuality.max.label.optionLabel, "Max")
	}
}
