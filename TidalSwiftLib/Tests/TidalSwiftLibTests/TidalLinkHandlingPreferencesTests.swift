//
//  TidalLinkHandlingPreferencesTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the toggle's default: an absent key must read as on, so an existing
/// install handles `tidal://` without a migration step.
final class TidalLinkHandlingPreferencesTests: XCTestCase {
	private var suiteName: String!
	private var defaults: UserDefaults!

	override func setUpWithError() throws {
		try super.setUpWithError()
		suiteName = "TidalLinkHandlingPreferencesTests-\(UUID().uuidString)"
		defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
	}

	override func tearDown() {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
		super.tearDown()
	}

	func testAbsentKeyDefaultsToOn() {
		XCTAssertNil(defaults.object(forKey: TidalLinkHandlingPreferences.enabledKey))
		XCTAssertTrue(TidalLinkHandlingPreferences.defaultEnabled)
		XCTAssertTrue(TidalLinkHandlingPreferences.isEnabled(in: defaults))
	}

	func testStoredOffIsReadAsOff() {
		defaults.set(false, forKey: TidalLinkHandlingPreferences.enabledKey)
		XCTAssertFalse(TidalLinkHandlingPreferences.isEnabled(in: defaults))
	}

	func testStoredOnIsReadAsOn() {
		defaults.set(true, forKey: TidalLinkHandlingPreferences.enabledKey)
		XCTAssertTrue(TidalLinkHandlingPreferences.isEnabled(in: defaults))
	}
}
