//
//  PageDecodingTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 16.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

final class PageDecodingTests: XCTestCase {
	private func fixture(named name: String) throws -> Data {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
			"Missing fixture \(name).json"
		)
		return try Data(contentsOf: url)
	}

	@MainActor
	func testHomePageDecodes() throws {
		let page = try JSONDecoder.custom.decode(Page.self, from: fixture(named: "home"))

		XCTAssertEqual(page.title, "Home")
		let modules = page.modules
		XCTAssertGreaterThanOrEqual(modules.count, 1)
		XCTAssertTrue(modules.contains { $0.knownType == .playlistList })
		XCTAssertTrue(modules.contains { $0.knownType == .trackList })
		XCTAssertTrue(modules.contains { $0.knownType == .albumList })

		let playlistModule = try XCTUnwrap(modules.first { $0.knownType == .playlistList })
		let playlistItem = try XCTUnwrap(playlistModule.pagedList?.items.first)
		XCTAssertEqual(playlistItem.kind, .playlist)
		XCTAssertNotNil(playlistItem.playlist?.uuid)
		XCTAssertNotNil(playlistItem.playlist?.title)

		let trackModule = try XCTUnwrap(modules.first { $0.knownType == .trackList })
		let trackItem = try XCTUnwrap(trackModule.pagedList?.items.first)
		XCTAssertEqual(trackItem.kind, .track)
		XCTAssertNotNil(trackItem.track?.id)
		XCTAssertNotNil(trackItem.track?.album.title)
	}

	@MainActor
	func testMixItemCarriesImages() throws {
		let page = try JSONDecoder.custom.decode(Page.self, from: fixture(named: "mixes"))
		let mixModule = try XCTUnwrap(page.modules.first { $0.knownType == .mixList })
		let mixItem = try XCTUnwrap(mixModule.pagedList?.items.first)
		XCTAssertEqual(mixItem.kind, .mix)
		let mix = try XCTUnwrap(mixItem.mix)
		XCTAssertNotNil(mix.images?.small?.url)
		XCTAssertNotNil(mix.images?.medium?.url)
		XCTAssertNotNil(mix.images?.large?.url)
	}

	@MainActor
	func testVideoAndPromotionItemsDecode() throws {
		let page = try JSONDecoder.custom.decode(Page.self, from: fixture(named: "videos"))
		let videoModule = try XCTUnwrap(page.modules.first { $0.knownType == .videoList })
		let videoItem = try XCTUnwrap(videoModule.pagedList?.items.first)
		XCTAssertEqual(videoItem.kind, .video)
		XCTAssertNotNil(videoItem.video?.id)

		let promoModule = try XCTUnwrap(page.modules.first { $0.knownType == .multipleTopPromotions })
		let promoItem = try XCTUnwrap(promoModule.items?.first)
		XCTAssertNotNil(promoItem.artifactId)
		XCTAssertNotNil(promoItem.imageId)
	}

	@MainActor
	func testUnknownModuleTypeSurvivesDecoding() throws {
		let json = """
		{"title":"Test","rows":[{"modules":[{"id":"1","type":"FUTURE_MODULE","title":"Future","description":"","pagedList":{"dataApiPath":"pages/data/x","limit":1,"offset":0,"totalNumberOfItems":0,"items":[]}}]}]}
		"""
		let page = try JSONDecoder.custom.decode(Page.self, from: Data(json.utf8))
		let module = try XCTUnwrap(page.modules.first)
		XCTAssertEqual(module.type, "FUTURE_MODULE")
		XCTAssertNil(module.knownType)
	}
}
