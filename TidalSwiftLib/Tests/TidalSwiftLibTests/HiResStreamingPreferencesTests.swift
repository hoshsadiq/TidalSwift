//
//  HiResStreamingPreferencesTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the cache-size clamp. The Preferences field is free text, so a number outside
/// the offered band can reach defaults; the budget must not be used out of band.
final class HiResStreamingPreferencesTests: XCTestCase {
	private var suiteName: String!
	private var defaults: UserDefaults!

	override func setUpWithError() throws {
		try super.setUpWithError()
		suiteName = "HiResStreamingPreferencesTests-\(UUID().uuidString)"
		defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
	}

	override func tearDown() {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
		super.tearDown()
	}

	func testUnsetCacheSizeUsesTheDefaultBudget() {
		XCTAssertEqual(
			HiResStreamingPreferences.cacheSizeBytes(in: defaults),
			HiResStreamingPreferences.defaultCacheBytes
		)
	}

	func testCacheSizeIsClampedToTheOfferedBand() {
		let gigabyte = HiResStreamingPreferences.bytesPerGigabyte
		let lower = HiResStreamingPreferences.cacheSizeRange.lowerBound * gigabyte
		let upper = HiResStreamingPreferences.cacheSizeRange.upperBound * gigabyte

		defaults.set(0, forKey: HiResStreamingPreferences.cacheSizeBytesKey)
		XCTAssertEqual(
			HiResStreamingPreferences.cacheSizeBytes(in: defaults),
			lower,
			"a typo of 0 must not set the budget to nothing"
		)

		defaults.set(9999 * gigabyte, forKey: HiResStreamingPreferences.cacheSizeBytesKey)
		XCTAssertEqual(
			HiResStreamingPreferences.cacheSizeBytes(in: defaults),
			upper,
			"a typo of 9999 GB must not become the budget"
		)
	}

	func testCacheSizeInsideTheBandIsUsedAsStored() {
		let stored = 3 * HiResStreamingPreferences.bytesPerGigabyte
		defaults.set(stored, forKey: HiResStreamingPreferences.cacheSizeBytesKey)
		XCTAssertEqual(HiResStreamingPreferences.cacheSizeBytes(in: defaults), stored)
	}
}
