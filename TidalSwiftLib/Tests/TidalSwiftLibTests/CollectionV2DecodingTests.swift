//
//  CollectionV2DecodingTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

final class CollectionV2DecodingTests: XCTestCase {
	private func fixture(named name: String) throws -> Data {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
			"Missing fixture \(name).json"
		)
		return try Data(contentsOf: url)
	}

	@MainActor
	func testCollectionMixesDecode() throws {
		let page = try JSONDecoder.custom.decode(CollectionMixPage.self, from: fixture(named: "collectionMixesV2"))

		XCTAssertEqual(page.items.count, 3)
		XCTAssertNil(page.cursor)
		XCTAssertNotNil(page.lastModifiedAt)

		let first = try XCTUnwrap(page.items.first)
		XCTAssertEqual(first.trn, "trn:mix:002eca1c48a9427af98d371d897416")
		XCTAssertEqual(first.itemType, "MIX")
		XCTAssertEqual(first.name, "My Mix 1")
		XCTAssertNotNil(first.addedAt)

		let data = first.data
		XCTAssertEqual(data.id, "002eca1c48a9427af98d371d897416")
		XCTAssertEqual(data.mixType, .audio)
		XCTAssertEqual(data.title, "My Mix 1")
		XCTAssertEqual(data.subTitle, "Harry Styles, Jonah Kagen, sombr and more")
		XCTAssertEqual(data.titleTextInfo?.text, "My Mix 1")
		XCTAssertEqual(data.titleTextInfo?.color, "#D09795")
		XCTAssertEqual(data.subTitleTextInfo?.text, "Harry Styles, Jonah Kagen, sombr and more")
		XCTAssertEqual(data.master, false)

		XCTAssertEqual(data.images?.small?.size, "SMALL")
		XCTAssertNotNil(data.images?.small?.url)
		XCTAssertEqual(data.images?.medium?.size, "MEDIUM")
		XCTAssertEqual(data.images?.medium?.width, 640)
		XCTAssertEqual(data.images?.medium?.height, 640)
		XCTAssertNotNil(data.images?.large?.url)
		XCTAssertNotNil(data.detailImages?.medium?.url)

		XCTAssertEqual(page.items[1].data.mixType, .video)
		XCTAssertEqual(page.items[1].name, "My Video Mix 2")
		XCTAssertEqual(page.items[2].name, "My Mix 8")

		// The adapter feeds the existing mix cards.
		let card = data.asMixesItem
		XCTAssertEqual(card.id, data.id)
		XCTAssertEqual(card.title, "My Mix 1")
		XCTAssertEqual(card.subTitle, "Harry Styles, Jonah Kagen, sombr and more")
		XCTAssertEqual(card.mixType, .audio)
		XCTAssertNotNil(card.images?.medium?.url)
		XCTAssertEqual(card.titleColor, "#D09795")
		XCTAssertEqual(card.subtitleColor, "#D09795")
	}

	/// A `MixesItem` saved before the colour fields existed must still decode:
	/// `ViewCache` and the navigation stack are persisted, so the new fields
	/// have to be optional.
	@MainActor
	func testMixesItemWithoutColoursStillDecodes() throws {
		let json = """
		{"id":"mix-1","title":"My Mix 1","subTitle":"Artist and more","mixType":"DAILY_MIX"}
		"""
		let item = try JSONDecoder.custom.decode(MixesItem.self, from: Data(json.utf8))

		XCTAssertEqual(item.id, "mix-1")
		XCTAssertEqual(item.title, "My Mix 1")
		XCTAssertEqual(item.subTitle, "Artist and more")
		XCTAssertEqual(item.mixType, .audio)
		XCTAssertNil(item.titleColor)
		XCTAssertNil(item.subtitleColor)
	}

	@MainActor
	func testEmptyCollectionMixesPageDecodes() throws {
		let json = """
		{"items":[],"cursor":"next-page","lastModifiedAt":"2026-09-22T06:11:02.405+0000"}
		"""
		let page = try JSONDecoder.custom.decode(CollectionMixPage.self, from: Data(json.utf8))

		XCTAssertTrue(page.items.isEmpty)
		XCTAssertEqual(page.cursor, "next-page")
		XCTAssertEqual(page.lastModifiedAt, "2026-09-22T06:11:02.405+0000")
	}

	/// A malformed element must not fail the page: the lossy array keeps the
	/// valid siblings and drops the bad ones.
	@MainActor
	func testMalformedCollectionMixIsDropped() throws {
		let json = """
		{"items":[
			{"trn":"trn:mix:1","itemType":"MIX","name":"My Mix 1","data":{"id":"1","mixType":"DAILY_MIX","title":"My Mix 1"}},
			"not-a-mix",
			{"trn":"trn:mix:2","itemType":"MIX","name":"No Data"},
			{"trn":"trn:mix:4","itemType":"MIX","data":{"mixType":"DAILY_MIX"}},
			{"trn":"trn:mix:3","itemType":"MIX","name":"My Mix 3","data":{"id":"3","mixType":"FUTURE_MIX","title":"My Mix 3"}}
		],"cursor":null,"lastModifiedAt":null}
		"""
		let page = try JSONDecoder.custom.decode(CollectionMixPage.self, from: Data(json.utf8))

		XCTAssertEqual(page.items.count, 2)
		XCTAssertEqual(page.items.map(\.name), ["My Mix 1", "My Mix 3"])
		XCTAssertEqual(page.items.last?.data.mixType, .unknown)
	}

	@MainActor
	func testMixCollectionChangeDecodes() throws {
		let removeJSON = """
		{"deletedItems":[],"itemsNotRemoved":["bogus-mix"],"lastModifiedAt":"2026-09-22T06:11:02.405+0000"}
		"""
		let remove = try JSONDecoder.custom.decode(MixCollectionChange.self, from: Data(removeJSON.utf8))
		XCTAssertEqual(remove.deletedItems, [])
		XCTAssertEqual(remove.itemsNotRemoved, ["bogus-mix"])
		XCTAssertNil(remove.addedItems)
		XCTAssertNotNil(remove.lastModifiedAt)

		let addJSON = """
		{"addedItems":["mix-1"],"itemsNotAdded":[],"lastModifiedAt":"2026-09-22T06:11:02.405+0000"}
		"""
		let add = try JSONDecoder.custom.decode(MixCollectionChange.self, from: Data(addJSON.utf8))
		XCTAssertEqual(add.addedItems, ["mix-1"])
		XCTAssertEqual(add.itemsNotAdded, [])
		XCTAssertNil(add.deletedItems)
	}

	/// The success body shape is unverified, so an unknown body must still
	/// decode (all fields nil) rather than failing.
	@MainActor
	func testUnknownMixCollectionChangeBodyDecodes() throws {
		let json = """
		{"httpStatus":500,"subStatus":80005}
		"""
		let change = try JSONDecoder.custom.decode(MixCollectionChange.self, from: Data(json.utf8))

		XCTAssertNil(change.addedItems)
		XCTAssertNil(change.itemsNotAdded)
		XCTAssertNil(change.deletedItems)
		XCTAssertNil(change.itemsNotRemoved)
		XCTAssertNil(change.lastModifiedAt)
	}

	@MainActor
	func testPlaylistItemsTilesEnvelopeDecodes() throws {
		let json = """
		{"limit":4,"offset":0,"totalNumberOfItems":765,"items":[
			{"cut":null,"item":\(trackJSON(id: 1, cover: "cover-1")),"type":"track"},
			{"cut":null,"item":\(trackJSON(id: 2, cover: nil)),"type":"track"},
			{"cut":null,"item":null,"type":"track"},
			"not-an-item",
			{"cut":null,"item":\(trackJSON(id: 3, cover: "cover-3")),"type":"track"}
		]}
		"""
		let page = try JSONDecoder.custom.decode(PlaylistItemsPage.self, from: Data(json.utf8))

		XCTAssertEqual(page.items.count, 4)
		XCTAssertEqual(page.items.first?.type, "track")
		XCTAssertEqual(page.items.compactMap { $0.item?.album.cover }, ["cover-1", "cover-3"])
	}

	private func trackJSON(id: Int, cover: String?) -> String {
		let coverJSON = cover.map { "\"\($0)\"" } ?? "null"
		return """
		{"id":\(id),"title":"Track \(id)","duration":200,"replayGain":-7.4,"allowStreaming":true,"streamReady":true,"trackNumber":1,"volumeNumber":1,"popularity":50,"url":"https://tidal.com/track/\(id)","editable":false,"explicit":false,"artists":[{"id":1,"name":"Artist"}],"album":{"id":10,"title":"Album","cover":\(coverJSON)}}
		"""
	}
}
