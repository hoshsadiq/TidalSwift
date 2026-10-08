//
//  AudioQualityTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Pins the `AudioQuality` raw-value contract: the unknown string must stop throwing.
final class AudioQualityTests: XCTestCase {
	private struct QualityEnvelope: Decodable {
		let audioQuality: AudioQuality
	}

	@MainActor
	func testKnownQualityStringsDecodeToTheirCases() throws {
		let expected: [(String, AudioQuality)] = [
			("HI_RES_LOSSLESS", .max),
			("LOSSLESS", .high),
			("HIGH", .medium),
			("LOW", .low)
		]
		for (raw, quality) in expected {
			let decoded = try JSONDecoder.custom.decode(AudioQuality.self, from: Data("\"\(raw)\"".utf8))
			XCTAssertEqual(decoded, quality, "\(raw) should decode to \(quality)")
		}
	}

	@MainActor
	func testQualityDecodesFromJSONObject() throws {
		let json = #"{"audioQuality":"HI_RES_LOSSLESS"}"#
		let envelope = try JSONDecoder.custom.decode(QualityEnvelope.self, from: Data(json.utf8))
		XCTAssertEqual(envelope.audioQuality, .max)
	}

	/// A future quality string must not fail the whole payload: the decoder maps it to
	/// `.high` instead of throwing.
	@MainActor
	func testUnknownQualityStringDoesNotThrow() {
		let json = #""SUPER_HI_RES_LOSSLESS""#
		XCTAssertNoThrow(try JSONDecoder.custom.decode(AudioQuality.self, from: Data(json.utf8)))
	}
}
