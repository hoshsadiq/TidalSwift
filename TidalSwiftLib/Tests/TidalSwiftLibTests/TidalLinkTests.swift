//
//  TidalLinkTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the parsing a pasted or shared Tidal link goes through: which item a link names,
/// and when a link is rejected.
@MainActor
final class TidalLinkTests: XCTestCase {
	private let playlistId = "01234567-89ab-cdef-0123-456789abcdef"

	func testBrowseLinksParseToTheirItem() {
		XCTAssertEqual(TidalLink(string: "https://tidal.com/browse/album/123"), .album(id: 123))
		XCTAssertEqual(TidalLink(string: "https://tidal.com/browse/artist/456"), .artist(id: 456))
		XCTAssertEqual(TidalLink(string: "https://tidal.com/browse/track/789"), .track(id: 789))
		XCTAssertEqual(TidalLink(string: "https://tidal.com/browse/playlist/\(playlistId)"), .playlist(uuid: playlistId))
	}

	func testListenAndWwwHostsAreAccepted() {
		XCTAssertEqual(TidalLink(string: "https://listen.tidal.com/track/123/u"), .track(id: 123))
		XCTAssertEqual(TidalLink(string: "http://www.tidal.com/playlist/\(playlistId)"), .playlist(uuid: playlistId))
	}

	func testTidalSchemeTreatsTheHostAsTheType() {
		XCTAssertEqual(TidalLink(string: "tidal://artist/123"), .artist(id: 123))
		XCTAssertEqual(TidalLink(string: "tidal://album/123"), .album(id: 123))
		XCTAssertEqual(TidalLink(string: "tidal://playlist/\(playlistId)"), .playlist(uuid: playlistId))
	}

	func testSchemeLessLinksGetHTTPS() {
		XCTAssertEqual(TidalLink(string: "tidal.com/browse/track/123"), .track(id: 123))
	}

	func testSurroundingWhitespaceIsIgnored() {
		XCTAssertEqual(TidalLink(string: "  https://tidal.com/browse/album/123\n"), .album(id: 123))
	}

	func testTheLastItemWins() {
		XCTAssertEqual(TidalLink(string: "https://tidal.com/browse/album/123/track/456"), .track(id: 456))
	}

	func testMissingOrMalformedIdsAreRejected() {
		XCTAssertNil(TidalLink(string: "https://tidal.com/browse/track/abc"))
		XCTAssertNil(TidalLink(string: "https://tidal.com/browse/track"))
		XCTAssertNil(TidalLink(string: "https://tidal.com/browse/playlist/not-a-uuid"))
	}

	func testNonTidalHostsAreRejected() {
		XCTAssertNil(TidalLink(string: "https://example.com/track/123"))
		XCTAssertNil(TidalLink(string: "https://tidal.com.evil.com/track/123"))
	}

	func testUnknownTypesAreRejected() {
		XCTAssertNil(TidalLink(string: "https://tidal.com/browse/mix/123"))
		XCTAssertNil(TidalLink(string: "tidal://login/auth"))
	}
}
