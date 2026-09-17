//
//  MixDecodingTests.swift
//  TidalSwiftLibTests
//
//  Created by Melvin Gundlach on 16.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

final class MixDecodingTests: XCTestCase {
	private func fixture(named name: String) throws -> Data {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
			"Missing fixture \(name).json"
		)
		return try Data(contentsOf: url)
	}

	@MainActor
	func testMixesDecodeAllTypesWithImages() throws {
		let mixes = try JSONDecoder.custom.decode(Mixes.self, from: fixture(named: "mixes"))
		let items = mixes.rows[0].modules[0].pagedList.items

		print("decoded mix count:", items.count)
		for item in items {
			print("mixType:", item.mixType.rawValue, "| title:", item.title, "| images:", item.images != nil)
		}

		XCTAssertEqual(items.count, 17)
		XCTAssertTrue(items.contains { $0.mixType == .discovery })
		XCTAssertTrue(items.contains { $0.mixType == .audio })
		XCTAssertTrue(items.contains { $0.mixType == .video })

		let first = try XCTUnwrap(items.first)
		XCTAssertNotNil(first.images?.small?.url)
		XCTAssertNotNil(first.images?.medium?.url)
		XCTAssertNotNil(first.images?.large?.url)
	}

	@MainActor
	func testUnknownMixTypeFallsBack() throws {
		let json = """
		{"selfLink":null,"id":"x","title":"t","rows":[{"modules":[{"id":"m","width":1,"title":"t","pagedList":{"limit":1,"offset":0,"totalNumberOfItems":1,"dataApiPath":"p","items":[{"id":"1","title":"T","subTitle":"S","mixType":"FUTURE_MIX"}]}}]}]}
		"""
		let mixes = try JSONDecoder.custom.decode(Mixes.self, from: Data(json.utf8))
		let item = try XCTUnwrap(mixes.rows.first?.modules.first?.pagedList.items.first)
		print("invented mixType FUTURE_MIX decoded as:", item.mixType.rawValue)
		XCTAssertEqual(item.mixType, .unknown)
		XCTAssertNil(item.graphic)
		XCTAssertNil(item.images)
	}
}
