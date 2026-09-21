//
//  LRCLIBDecodingTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

@MainActor
final class LRCLIBDecodingTests: XCTestCase {
	private func decodeRecord(_ json: String) throws -> LRCLIBRecord {
		try JSONDecoder().decode(LRCLIBRecord.self, from: Data(json.utf8))
	}

	func testRecordWithSyncedLyrics() throws {
		let record = try decodeRecord("""
		{
		  "id": 38650190,
		  "trackName": "Pillow Fight",
		  "artistName": "Tinashe",
		  "albumName": "Pillow Fight / I’d Rather Be Alone",
		  "duration": 142.0,
		  "instrumental": false,
		  "plainLyrics": "Oh-oh\\nDon't ever let a pretty face fool ya",
		  "syncedLyrics": "[00:09.98]Oh-oh\\n[00:10.84]Don't ever let a pretty face fool ya"
		}
		""")

		XCTAssertEqual(record.duration, 142)
		XCTAssertEqual(record.lyrics?.lrc, "[00:09.98]Oh-oh\n[00:10.84]Don't ever let a pretty face fool ya")
		XCTAssertEqual(record.lyrics?.plain, "Oh-oh\nDon't ever let a pretty face fool ya")
	}

	func testRecordWithoutSyncedLyrics() throws {
		let record = try decodeRecord("""
		{"duration": 100.0, "instrumental": false, "plainLyrics": "Just plain", "syncedLyrics": null}
		""")

		XCTAssertNil(record.lyrics?.lrc)
		XCTAssertEqual(record.lyrics?.plain, "Just plain")
	}

	func testEmptySyncedLyricsCountsAsMissing() throws {
		let record = try decodeRecord("""
		{"duration": 100.0, "instrumental": false, "plainLyrics": "Just plain", "syncedLyrics": ""}
		""")

		XCTAssertNil(record.lyrics?.lrc)
		XCTAssertEqual(record.lyrics?.plain, "Just plain")
	}

	func testInstrumentalRecordHasNoLyrics() throws {
		let record = try decodeRecord("""
		{"duration": 100.0, "instrumental": true, "plainLyrics": null, "syncedLyrics": null}
		""")

		XCTAssertNil(record.lyrics)
	}

	func testTrackNotFoundBodyDecodesAsError() throws {
		let json = """
		{"message":"Failed to find specified track","name":"TrackNotFound","statusCode":404}
		"""

		let error = try JSONDecoder().decode(LRCLIBError.self, from: Data(json.utf8))
		XCTAssertEqual(error.name, "TrackNotFound")
		XCTAssertEqual(error.statusCode, 404)

		let record = try decodeRecord(json)
		XCTAssertNil(record.lyrics)
	}

	func testBestMatchPrefersSyncedThenClosestDuration() throws {
		let records = try JSONDecoder().decode([LRCLIBRecord].self, from: Data("""
		[
		  {"duration": 141.0, "instrumental": false, "plainLyrics": "A", "syncedLyrics": null},
		  {"duration": 237.0, "instrumental": false, "plainLyrics": "B", "syncedLyrics": "[00:01.00]B"},
		  {"duration": 142.0, "instrumental": false, "plainLyrics": "C", "syncedLyrics": "[00:01.00]C"}
		]
		""".utf8))

		let match = Session.bestLRCLIBMatch(in: records, duration: 141)
		XCTAssertEqual(match?.plainLyrics, "C")
	}

	func testBestMatchFallsBackToClosestDurationWithoutSynced() throws {
		let records = try JSONDecoder().decode([LRCLIBRecord].self, from: Data("""
		[
		  {"duration": 141.0, "instrumental": false, "plainLyrics": "A", "syncedLyrics": null},
		  {"duration": 237.0, "instrumental": false, "plainLyrics": "B", "syncedLyrics": null}
		]
		""".utf8))

		let match = Session.bestLRCLIBMatch(in: records, duration: 140)
		XCTAssertEqual(match?.plainLyrics, "A")
	}

	func testBestMatchSkipsInstrumentals() throws {
		let records = try JSONDecoder().decode([LRCLIBRecord].self, from: Data("""
		[
		  {"duration": 100.0, "instrumental": true, "plainLyrics": null, "syncedLyrics": "[00:01.00]Instrumental"},
		  {"duration": 100.0, "instrumental": false, "plainLyrics": "Plain", "syncedLyrics": null}
		]
		""".utf8))

		let match = Session.bestLRCLIBMatch(in: records, duration: 100)
		XCTAssertEqual(match?.plainLyrics, "Plain")
	}

	func testBestMatchReturnsNilForEmptyResults() {
		XCTAssertNil(Session.bestLRCLIBMatch(in: [], duration: 100))
	}
}
