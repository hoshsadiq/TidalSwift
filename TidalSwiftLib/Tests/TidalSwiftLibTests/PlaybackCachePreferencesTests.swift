//
//  PlaybackCachePreferencesTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the cache-size clamp. The Preferences field is free text, so a number outside
/// the offered band can reach defaults; the budget must not be used out of band.
final class PlaybackCachePreferencesTests: XCTestCase {
	private var suiteName: String!
	private var defaults: UserDefaults!

	override func setUpWithError() throws {
		try super.setUpWithError()
		suiteName = "PlaybackCachePreferencesTests-\(UUID().uuidString)"
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
			PlaybackCachePreferences.cacheSizeBytes(in: defaults),
			PlaybackCachePreferences.defaultCacheBytes
		)
	}

	func testCacheSizeIsClampedToTheOfferedBand() {
		let gigabyte = PlaybackCachePreferences.bytesPerGigabyte
		let lower = PlaybackCachePreferences.cacheSizeRange.lowerBound * gigabyte
		let upper = PlaybackCachePreferences.cacheSizeRange.upperBound * gigabyte

		defaults.set(0, forKey: PlaybackCachePreferences.cacheSizeBytesKey)
		XCTAssertEqual(
			PlaybackCachePreferences.cacheSizeBytes(in: defaults),
			lower,
			"a typo of 0 must not set the budget to nothing"
		)

		defaults.set(9999 * gigabyte, forKey: PlaybackCachePreferences.cacheSizeBytesKey)
		XCTAssertEqual(
			PlaybackCachePreferences.cacheSizeBytes(in: defaults),
			upper,
			"a typo of 9999 GB must not become the budget"
		)
	}

	func testCacheSizeInsideTheBandIsUsedAsStored() {
		let stored = 3 * PlaybackCachePreferences.bytesPerGigabyte
		defaults.set(stored, forKey: PlaybackCachePreferences.cacheSizeBytesKey)
		XCTAssertEqual(PlaybackCachePreferences.cacheSizeBytes(in: defaults), stored)
	}
}
