//
//  OfflineAddedDateTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Pins `OfflineDB.recordAddedDate(for:)`: recording the same track twice must
/// not move its "added to offline" date, or a re-add would reorder the library.
@MainActor
final class OfflineAddedDateTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineAddedDate")

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	func testRecordAddedDateIsIdempotent() {
		let db = OfflineDB(defaults: offlineLibrary.defaults)
		let trackId = Int.random(in: 900_000_000...999_999_999)

		db.recordAddedDate(for: trackId)
		let first = db.trackAddedDates[trackId]
		XCTAssertNotNil(first)

		db.recordAddedDate(for: trackId)
		XCTAssertEqual(db.trackAddedDates[trackId], first)
	}
}
