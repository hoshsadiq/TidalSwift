//
//  FeedDecodingTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

final class FeedDecodingTests: XCTestCase {
	private func fixture(named name: String) throws -> Data {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
			"Missing fixture \(name).json"
		)
		return try Data(contentsOf: url)
	}

	@MainActor
	func testFeedActivitiesDecode() throws {
		let feed = try JSONDecoder.custom.decode(FeedResponse.self, from: fixture(named: "feedActivities"))

		XCTAssertEqual(feed.activities.count, 2)
		XCTAssertEqual(feed.stats?.totalNotSeenActivities, 0)

		let first = try XCTUnwrap(feed.activities.first)
		XCTAssertEqual(first.seen, true)

		let activity = try XCTUnwrap(first.followableActivity)
		XCTAssertEqual(activity.activityType, "NEW_ALBUM_RELEASE")
		XCTAssertEqual(activity.kind, .newAlbumRelease)
		XCTAssertNotNil(activity.occurredAt)
		XCTAssertNil(activity.historyMix)

		let album = try XCTUnwrap(activity.album)
		XCTAssertEqual(album.id, 161451880)
		XCTAssertEqual(album.title, "A very chilly christmas")
		XCTAssertEqual(album.cover, "c9536722-36cb-4464-b77b-c318370f9d74")
		XCTAssertEqual(album.numberOfTracks, 15)
		XCTAssertEqual(album.artists?.first?.name, "Chilly Gonzales")
		XCTAssertNotNil(album.releaseDate)
	}

	/// `occurredAt` carries six fractional-second digits ("…54.927211Z"); the
	/// shared formatter parses them (truncating to milliseconds).
	@MainActor
	func testOccurredAtFractionalSecondsDecode() throws {
		let feed = try JSONDecoder.custom.decode(FeedResponse.self, from: fixture(named: "feedActivities"))
		let activity = try XCTUnwrap(feed.activities.first?.followableActivity)
		let occurredAt = try XCTUnwrap(activity.occurredAt)
		XCTAssertEqual(occurredAt.timeIntervalSince1970, 1605222714.927, accuracy: 0.001)
	}

	/// The album's date-only `releaseDate` ("2020-11-13") and its v2
	/// `streamStartDate` ("2020-11-06T00:00:00Z", which the shared `Album`
	/// model rejects) both decode through the tolerant v2 album subset.
	@MainActor
	func testAlbumReleaseDateDecodes() throws {
		let feed = try JSONDecoder.custom.decode(FeedResponse.self, from: fixture(named: "feedActivities"))
		let album = try XCTUnwrap(feed.activities.first?.followableActivity?.album)
		let releaseDate = try XCTUnwrap(album.releaseDate)
		XCTAssertEqual(releaseDate.timeIntervalSince1970, 1605225600, accuracy: 0.001) // 2020-11-13 00:00 UTC
		XCTAssertNil(album.streamStartDate)
	}

	@MainActor
	func testEmptyFeedDecodes() throws {
		let feed = try JSONDecoder.custom.decode(FeedResponse.self, from: fixture(named: "feedActivitiesEmpty"))
		XCTAssertTrue(feed.activities.isEmpty)
		XCTAssertEqual(feed.stats?.totalNotSeenActivities, 0)
	}

	/// A malformed element must not fail the response: the lossy array keeps
	/// the valid siblings and drops the bad one.
	@MainActor
	func testMalformedActivityIsDropped() throws {
		let json = """
		{"activities":[
			{"followableActivity":{"activityType":"NEW_ALBUM_RELEASE","occurredAt":"2020-11-12T23:11:54.927211Z"},"seen":true},
			"not-an-activity",
			{"followableActivity":{"activityType":"NEW_ALBUM_RELEASE"},"seen":"not-a-bool"},
			{"followableActivity":{"activityType":"FUTURE_ACTIVITY_TYPE"},"seen":false}
		],"stats":{"totalNotSeenActivities":1}}
		"""
		let feed = try JSONDecoder.custom.decode(FeedResponse.self, from: Data(json.utf8))

		XCTAssertEqual(feed.activities.count, 2)
		XCTAssertEqual(
			feed.activities.map { $0.followableActivity?.activityType },
			["NEW_ALBUM_RELEASE", "FUTURE_ACTIVITY_TYPE"]
		)
		XCTAssertEqual(feed.activities.first?.seen, true)
		XCTAssertEqual(feed.activities.last?.seen, false)
		XCTAssertEqual(feed.activities.last?.followableActivity?.kind, .unknown)
		XCTAssertEqual(feed.stats?.totalNotSeenActivities, 1)
	}

	/// The live `NEW_HISTORY_MIX` payload shape could not be pinned, so this
	/// payload is synthetic: it only proves the activity survives decoding and
	/// the tolerant `historyMix` subset decodes what it can.
	@MainActor
	func testHistoryMixActivityDecodesTolerantly() throws {
		let json = """
		{"activities":[{"followableActivity":{"activityType":"NEW_HISTORY_MIX","historyMix":{"id":"mix-1","title":"My History Mix","subtitle":"Songs you played","images":{"MEDIUM":{"url":"https://example.com/mix.jpg","width":640,"height":640}}}},"seen":false}],"stats":{"totalNotSeenActivities":1}}
		"""
		let feed = try JSONDecoder.custom.decode(FeedResponse.self, from: Data(json.utf8))

		let activity = try XCTUnwrap(feed.activities.first?.followableActivity)
		XCTAssertEqual(activity.kind, .newHistoryMix)
		XCTAssertNil(activity.album)

		let mix = try XCTUnwrap(activity.historyMix)
		XCTAssertEqual(mix.id, "mix-1")
		XCTAssertEqual(mix.displayTitle, "My History Mix")
		XCTAssertEqual(mix.displaySubtitle, "Songs you played")
		XCTAssertEqual(mix.images?.medium?.url.absoluteString, "https://example.com/mix.jpg")
	}

	/// Only activities with a known type and a decodable payload can be shown;
	/// the Feed falls back to releases when none are displayable.
	@MainActor
	func testActivityIsDisplayable() throws {
		let json = """
		{"activities":[
			{"followableActivity":{"activityType":"FUTURE_ACTIVITY_TYPE"},"seen":false},
			{"followableActivity":{"activityType":"NEW_ALBUM_RELEASE"},"seen":false},
			{"followableActivity":{"activityType":"NEW_HISTORY_MIX","historyMix":{"id":"mix-1","title":"My History Mix"}},"seen":false},
			{"seen":false}
		],"stats":{"totalNotSeenActivities":1}}
		"""
		let feed = try JSONDecoder.custom.decode(FeedResponse.self, from: Data(json.utf8))

		XCTAssertEqual(feed.activities.map(\.isDisplayable), [false, false, true, false])
	}

	@MainActor
	func testNewestFirstDedupesSortsAndPrefixes() throws {
		let albums = [
			try album(id: 1, title: "Older", releaseDate: "2024-01-01"),
			try album(id: 2, title: "Newest", releaseDate: "2025-06-01"),
			try album(id: 3, title: "Undated", releaseDate: nil),
			try album(id: 1, title: "Older", releaseDate: "2024-01-01")
		]

		let sorted = Helpers.newestFirst(albums, number: 10)
		XCTAssertEqual(sorted.map(\.id), [2, 1, 3])
		XCTAssertEqual(Helpers.newestFirst(albums, number: 2).map(\.id), [2, 1])
	}

	/// TIDAL lists one entry per variant (explicit/clean × quality), so the
	/// fallback collapses them to one row per release: Dolby Atmos first, then
	/// the best quality the setting allows, explicit before clean.
	@MainActor
	func testCollapseVariantsKeepsBestVariant() throws {
		let hustla = [
			try album(id: 1, title: "Real Hustla", releaseDate: "2026-06-12", explicit: true, audioQuality: "LOSSLESS"),
			try album(id: 2, title: "Real Hustla", releaseDate: "2026-06-12", audioQuality: "HI_RES_LOSSLESS"),
			try album(id: 3, title: "Real Hustla", releaseDate: "2026-06-12", explicit: true, audioQuality: "LOW", audioModes: "DOLBY_ATMOS"),
			try album(id: 4, title: "Real Hustla", releaseDate: "2026-06-12", audioQuality: "LOW", audioModes: "DOLBY_ATMOS")
		]
		// Atmos represents the release, explicit among the Atmos copies.
		XCTAssertEqual(Helpers.collapseVariants(hustla, maxQuality: .max).map(\.id), [3])

		let stereo = [
			try album(id: 1, title: "Real Hustla", releaseDate: "2026-06-12", explicit: true, audioQuality: "LOSSLESS"),
			try album(id: 2, title: "Real Hustla", releaseDate: "2026-06-12", audioQuality: "HI_RES_LOSSLESS")
		]
		// The setting is the ceiling: hi-res is not preferred at a High cap, and
		// wins when the cap allows it.
		XCTAssertEqual(Helpers.collapseVariants(stereo, maxQuality: .high).map(\.id), [1])
		XCTAssertEqual(Helpers.collapseVariants(stereo, maxQuality: .max).map(\.id), [2])

		let cleanOnly = [
			try album(id: 5, title: "Pull Over", releaseDate: "2026-04-17", audioQuality: "LOSSLESS"),
			try album(id: 6, title: "Pull Over", releaseDate: "2026-04-17", audioQuality: "HI_RES_LOSSLESS")
		]
		XCTAssertEqual(Helpers.collapseVariants(cleanOnly, maxQuality: .max).map(\.id), [6])

		let sameTier = [
			try album(id: 8, title: "44 Bars", releaseDate: "2025-12-05", audioQuality: "LOSSLESS"),
			try album(id: 7, title: "44 Bars", releaseDate: "2025-12-05", audioQuality: "LOSSLESS")
		]
		XCTAssertEqual(Helpers.collapseVariants(sameTier, maxQuality: .max).map(\.id), [7])

		let otherArtist = try album(id: 9, title: "Real Hustla", releaseDate: "2026-06-12", artist: "Someone Else")
		XCTAssertEqual(Helpers.collapseVariants(hustla + [otherArtist], maxQuality: .max).count, 2)
		XCTAssertEqual(
			Helpers.newestFirst(Helpers.collapseVariants(hustla + [otherArtist], maxQuality: .max), number: 10).count,
			2
		)
	}

	@MainActor
	private func album(
		id: Int,
		title: String,
		releaseDate: String?,
		artist: String = "A",
		explicit: Bool = false,
		audioQuality: String = "LOSSLESS",
		audioModes: String? = nil,
		version: String? = nil
	) throws -> Album {
		let date = releaseDate.map { "\"\($0)\"" } ?? "null"
		let modesJSON = audioModes.map { "[\"\($0)\"]" } ?? "null"
		let versionJSON = version.map { "\"\($0)\"" } ?? "null"
		let json = """
		{"id":\(id),"title":"\(title)","releaseDate":\(date),"explicit":\(explicit),"audioQuality":"\(audioQuality)","audioModes":\(modesJSON),"version":\(versionJSON),"artist":{"id":1,"name":"\(artist)"}}
		"""
		return try JSONDecoder.custom.decode(Album.self, from: Data(json.utf8))
	}
}
