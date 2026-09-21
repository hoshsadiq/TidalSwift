//
//  HomeFeedDecodingTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

final class HomeFeedDecodingTests: XCTestCase {
	private func fixture(named name: String) throws -> Data {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
			"Missing fixture \(name).json"
		)
		return try Data(contentsOf: url)
	}

	@MainActor
	func testHomeFeedDecodes() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Phone"))

		XCTAssertGreaterThanOrEqual(feed.items.count, 11)
		XCTAssertEqual(feed.items.first?.title, "Custom mixes")
		XCTAssertEqual(feed.items.first?.moduleId, "DAILY_MIXES")
		XCTAssertEqual(feed.items.first?.viewAll, "home/pages/DAILY_MIXES/view-all")
		XCTAssertNotNil(feed.page?.cursor)

		let vibes = try XCTUnwrap(feed.header?.vibes?.items)
		XCTAssertEqual(vibes.map(\.name), ["For you", "Staff Picks", "Uploads"])
		XCTAssertEqual(vibes.map(\.type), ["STATIC", "EDITORIAL", "UPLOADS"])
	}

	@MainActor
	func testMixItemsDecode() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Phone"))
		let module = try XCTUnwrap(feed.items.first)
		let mixItems = module.items.filter { $0.type == "MIX" }
		XCTAssertEqual(mixItems.count, 4)

		let mix = try XCTUnwrap(mixItems.first?.mix)
		XCTAssertEqual(mix.title, "My Daily Discovery")
		XCTAssertEqual(mix.mixType, .discovery)
		XCTAssertEqual(mix.type, "DISCOVERY_MIX")
		XCTAssertFalse(mix.subTitle.isEmpty)
		XCTAssertEqual(mix.mixImages.count, 3)
		XCTAssertNotNil(mix.smallImage?.url)
		XCTAssertNotNil(mix.mediumImage?.url)
		XCTAssertNotNil(mix.largeImage?.url)

		let card = mix.asMixesItem
		XCTAssertEqual(card.id, mix.id)
		XCTAssertEqual(card.title, "My Daily Discovery")
		XCTAssertEqual(card.subTitle, mix.subTitle)
		XCTAssertEqual(card.mixType, .discovery)
		XCTAssertNotNil(card.images?.small?.url)
		XCTAssertNotNil(card.images?.medium?.url)
		XCTAssertNotNil(card.images?.large?.url)
	}

	@MainActor
	func testViewAllDecodes() throws {
		let viewAll = try JSONDecoder.custom.decode(HomeFeedViewAll.self, from: fixture(named: "homeFeedV2ViewAllDailyMixes"))

		XCTAssertEqual(viewAll.title, "Custom mixes")
		XCTAssertEqual(viewAll.itemLayout, "GRID")
		XCTAssertEqual(viewAll.items.count, 10)
		XCTAssertEqual(
			viewAll.items.compactMap { $0.mix?.title },
			["My Daily Discovery", "My Mix 1", "My Mix 2", "My Mix 3", "My Mix 4",
			 "My Mix 5", "My Mix 6", "My Mix 7", "My Mix 8", "My New Arrivals"]
		)
		XCTAssertTrue(viewAll.items.allSatisfy { $0.mix?.mixType != .unknown })
	}

	@MainActor
	func testUnknownTypesSurviveDecoding() throws {
		let json = """
		{"uuid":"x","page":{"cursor":null},"header":{"vibes":{"items":[]}},"items":[{"type":"FUTURE_MODULE","moduleId":"m","title":"Future","items":[{"type":"FUTURE_ITEM","data":{"foo":"bar"}}]}]}
		"""
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: Data(json.utf8))
		let module = try XCTUnwrap(feed.items.first)
		XCTAssertEqual(module.type, "FUTURE_MODULE")
		let item = try XCTUnwrap(module.items.first)
		XCTAssertEqual(item.type, "FUTURE_ITEM")
		XCTAssertNil(item.mix)
		XCTAssertNil(item.album)
		XCTAssertNil(item.track)
		XCTAssertNil(item.artist)
		XCTAssertNil(item.playlist)
	}

	@MainActor
	func testUndecodablePayloadLeavesItemNil() throws {
		let json = """
		{"uuid":"x","items":[{"type":"GRID_CARD","items":[{"type":"MIX","data":{"id":123}},{"type":"ALBUM","data":{"id":"not-an-int"}}]}]}
		"""
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: Data(json.utf8))
		let items = try XCTUnwrap(feed.items.first?.items)
		XCTAssertEqual(items.count, 2)
		XCTAssertNil(items[0].mix)
		XCTAssertNil(items[1].album)
	}

	/// Documents which shared entity codables the v2 payloads actually decode
	/// into: `Artist` is reused as-is, while album/track/playlist payloads need
	/// the purpose-built `HomeFeed*` structs (see their doc comments).
	@MainActor
	func testSharedCodableReuse() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Phone"))
		let items = feed.items.flatMap(\.items)

		let artistItem = try XCTUnwrap(items.first { $0.type == "ARTIST" })
		XCTAssertNotNil(artistItem.artist)
		XCTAssertEqual(artistItem.artist?.name, "Teflon")

		let albumItem = try XCTUnwrap(items.first { $0.type == "ALBUM" })
		XCTAssertNotNil(albumItem.album)
		XCTAssertNotNil(albumItem.album?.title)

		let trackItem = try XCTUnwrap(items.first { $0.type == "TRACK" })
		XCTAssertNotNil(trackItem.track)
		XCTAssertNotNil(trackItem.track?.album?.title)

		let playlistItem = try XCTUnwrap(items.first { $0.type == "PLAYLIST" })
		XCTAssertNotNil(playlistItem.playlist)
		XCTAssertNotNil(playlistItem.playlist?.title)
	}

	@MainActor
	func testAlbumConversion() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Phone"))
		let payload = try XCTUnwrap(feed.items.flatMap(\.items).first { $0.type == "ALBUM" }?.album)
		let album = payload.asAlbum

		XCTAssertEqual(album.id, payload.id)
		XCTAssertEqual(album.title, payload.title)
		XCTAssertNotNil(payload.cover)
		XCTAssertNotNil(album.cover)
		XCTAssertEqual(album.cover, payload.cover)
		XCTAssertEqual(album.numberOfTracks, payload.numberOfTracks)
		XCTAssertEqual(album.releaseDate, payload.releaseDate)
		XCTAssertEqual(album.artists?.count, payload.artists?.count)
		XCTAssertEqual(album.audioQuality, payload.audioQuality)
		XCTAssertNil(album.streamStartDate)
		XCTAssertNil(album.artist)
	}

	@MainActor
	func testTrackConversion() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Phone"))
		let payload = try XCTUnwrap(feed.items.flatMap(\.items).first { $0.type == "TRACK" }?.track)
		let track = payload.asTrack

		XCTAssertEqual(track.id, payload.id)
		XCTAssertEqual(track.title, payload.title)
		XCTAssertEqual(track.album.title, payload.album?.title)
		XCTAssertEqual(track.artists.count, payload.artists?.count)
		XCTAssertEqual(track.url.absoluteString, "https://tidal.com/browse/track/\(payload.id)")
		XCTAssertEqual(track.replayGain, payload.replayGain ?? 0)
		XCTAssertEqual(track.duration, payload.duration ?? 0)
		XCTAssertEqual(track.bpm, 132)
		XCTAssertEqual(track.key, "Eb")
		XCTAssertEqual(track.keyScale, "MINOR")
	}

	@MainActor
	func testPlaylistConversion() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Phone"))
		let payload = try XCTUnwrap(feed.items.flatMap(\.items).first { $0.type == "PLAYLIST" }?.playlist)
		let playlist = payload.asPlaylist

		XCTAssertEqual(playlist.uuid, payload.uuid)
		XCTAssertEqual(playlist.title, payload.title)
		XCTAssertEqual(playlist.publicPlaylist, payload.sharingLevel == "PUBLIC")
		XCTAssertTrue(playlist.publicPlaylist)
		XCTAssertEqual(playlist.type, .editorial)
		XCTAssertEqual(playlist.popularity, 0)
		XCTAssertEqual(playlist.numberOfTracks, payload.numberOfTracks ?? 0)
		XCTAssertEqual(playlist.duration, payload.duration ?? 0)
		XCTAssertNotNil(playlist.creator)
	}

	@MainActor
	func testMixConversionCarriesMediumImage() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Phone"))
		let mixes = feed.items.flatMap(\.items).compactMap { $0.mix }
		let dailyMix = try XCTUnwrap(mixes.first { $0.mixType == .audio })
		XCTAssertEqual(dailyMix.title, "My Mix 1")
		XCTAssertNotNil(dailyMix.asMixesItem.images?.small)
		XCTAssertNotNil(dailyMix.asMixesItem.images?.medium)
		XCTAssertNotNil(dailyMix.asMixesItem.images?.large)
	}

	@MainActor
	func testHomeFeedItemEncodeDecodeRoundTrip() throws {
		let json = """
		{"type":"TRACK","following":true,"numberOfFollowers":3,"data":{"id":42,"title":"Round Trip","duration":210,"album":{"id":7,"title":"Round Trip Album"}}}
		"""
		let item = try JSONDecoder.custom.decode(HomeFeedItem.self, from: Data(json.utf8))
		let data = try JSONEncoder().encode(item)
		let decoded = try JSONDecoder.custom.decode(HomeFeedItem.self, from: data)

		XCTAssertEqual(decoded.type, "TRACK")
		XCTAssertEqual(decoded.following, true)
		XCTAssertEqual(decoded.numberOfFollowers, 3)
		XCTAssertEqual(decoded.track?.id, 42)
		XCTAssertEqual(decoded.track?.title, "Round Trip")
		XCTAssertEqual(decoded.track?.duration, 210)
		XCTAssertEqual(decoded.track?.album?.id, 7)
		XCTAssertEqual(decoded.track?.album?.title, "Round Trip Album")
	}

	@MainActor
	func testTrackConversionWithoutAlbumUsesEmptyAlbum() throws {
		let json = """
		{"id":1,"title":"No Album","duration":100}
		"""
		let payload = try JSONDecoder.custom.decode(HomeFeedTrack.self, from: Data(json.utf8))
		let track = payload.asTrack

		XCTAssertEqual(track.album.id, 0)
		XCTAssertEqual(track.album.title, "")
		XCTAssertNil(track.album.cover)
		XCTAssertNil(track.album.releaseDate)
		XCTAssertTrue(track.artists.isEmpty)
		XCTAssertEqual(track.url.absoluteString, "https://tidal.com/browse/track/1")
	}

	@MainActor
	func testPlaylistConversionWithoutOptionalFieldsUsesFallbacks() throws {
		let json = """
		{"uuid":"bare-playlist","title":"Bare Playlist"}
		"""
		let payload = try JSONDecoder.custom.decode(HomeFeedPlaylist.self, from: Data(json.utf8))
		let playlist = payload.asPlaylist

		XCTAssertEqual(playlist.uuid, "bare-playlist")
		XCTAssertEqual(playlist.title, "Bare Playlist")
		XCTAssertEqual(playlist.numberOfTracks, 0)
		XCTAssertEqual(playlist.numberOfVideos, 0)
		XCTAssertEqual(playlist.duration, 0)
		XCTAssertEqual(playlist.lastUpdated, .distantPast)
		XCTAssertEqual(playlist.created, .distantPast)
		XCTAssertEqual(playlist.url.absoluteString, "https://tidal.com/browse/playlist/bare-playlist")
		XCTAssertEqual(playlist.type, .editorial)
		XCTAssertFalse(playlist.publicPlaylist)
		XCTAssertEqual(playlist.popularity, 0)
		XCTAssertNil(playlist.creator.id)
		XCTAssertNil(playlist.creator.name)
		XCTAssertNil(playlist.creator.url)
	}

	@MainActor
	func testMixConversionWithoutImagesLeavesImagesEmpty() throws {
		let json = """
		{"id":"mix-without-images","type":"DISCOVERY_MIX","titleTextInfo":{"text":"Discovery"},"subtitleTextInfo":{"text":"Subtitle"}}
		"""
		let mix = try JSONDecoder.custom.decode(HomeFeedMix.self, from: Data(json.utf8))
		XCTAssertTrue(mix.mixImages.isEmpty)

		let card = mix.asMixesItem
		XCTAssertEqual(card.id, "mix-without-images")
		XCTAssertEqual(card.title, "Discovery")
		XCTAssertEqual(card.subTitle, "Subtitle")
		XCTAssertEqual(card.mixType, .discovery)
		XCTAssertNotNil(card.images)
		XCTAssertNil(card.images?.small)
		XCTAssertNil(card.images?.medium)
		XCTAssertNil(card.images?.large)
	}

	@MainActor
	func testHorizontalListAndTrackListModulesDecode() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2ModuleTypes"))

		XCTAssertEqual(feed.items.map(\.type), ["HORIZONTAL_LIST", "TRACK_LIST"])

		let horizontalList = try XCTUnwrap(feed.items.first)
		XCTAssertEqual(horizontalList.title, "Horizontal list")
		XCTAssertEqual(horizontalList.viewAll, "home/pages/HORIZONTAL_LIST_MODULE/view-all")
		XCTAssertEqual(horizontalList.items.count, 2)
		XCTAssertEqual(horizontalList.items[0].album?.title, "Fixture Album")
		XCTAssertNotNil(horizontalList.items[0].album?.releaseDate)
		XCTAssertEqual(horizontalList.items[1].playlist?.title, "Fixture Playlist")

		let trackList = try XCTUnwrap(feed.items.last)
		XCTAssertEqual(trackList.items.count, 1)
		XCTAssertEqual(trackList.items[0].track?.title, "Fixture Track")
		XCTAssertEqual(trackList.items[0].track?.album?.title, "Fixture Album")
	}

	@MainActor
	func testMagazineItemsDecode() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Magazine"))
		let module = try XCTUnwrap(feed.items.first)
		XCTAssertEqual(module.moduleId, "STAFF_PICKS_PAGE_EXPLORE")
		XCTAssertEqual(module.items.count, 6)

		let magazines = module.items.compactMap(\.magazine)
		XCTAssertEqual(magazines.count, 5)
		XCTAssertEqual(magazines.map(\.type), ["CATEGORY_PAGES", "ALBUM", "EXTURL", "PLAYLIST", "FUTURE_MAGAZINE_KIND"])

		let category = try XCTUnwrap(magazines.first { $0.type == "CATEGORY_PAGES" })
		XCTAssertEqual(category.id, 70598)
		XCTAssertEqual(category.artifactId, "pages/m_lhm")
		XCTAssertEqual(category.header, "CELEBRATE")
		XCTAssertEqual(category.shortHeader, "Latinx Heritage Month")
		XCTAssertEqual(category.shortSubHeader, " ")
		XCTAssertEqual(category.groupName, "EXPLORE")
		XCTAssertEqual(category.priority, 30)
		XCTAssertNotNil(category.imageURL)

		let album = try XCTUnwrap(magazines.first { $0.type == "ALBUM" })
		XCTAssertEqual(album.artifactId, "539430")
		XCTAssertEqual(Int(album.artifactId), 539430)
		XCTAssertEqual(album.shortHeader, "Mariah Carey")
		XCTAssertEqual(album.shortSubHeader, "Emotions")

		let article = try XCTUnwrap(magazines.first { $0.type == "EXTURL" })
		XCTAssertEqual(article.artifactId, "https://tidal.com/magazine/article/jay-z-blueprint-20/1-80819")
		XCTAssertEqual(URL(string: article.artifactId)?.host, "tidal.com")

		let playlist = try XCTUnwrap(magazines.first { $0.type == "PLAYLIST" })
		XCTAssertEqual(playlist.artifactId, "72f59143-de09-43ac-9a16-e3d04cbcb067")
	}

	/// A future magazine flavour and a future item type must not fail the item,
	/// the module or the page.
	@MainActor
	func testMagazineUnknownFlavoursSurviveDecoding() throws {
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: fixture(named: "homeFeedV2Magazine"))
		let items = try XCTUnwrap(feed.items.first?.items)

		let futureMagazine = try XCTUnwrap(items.first { $0.magazine?.type == "FUTURE_MAGAZINE_KIND" })
		XCTAssertEqual(futureMagazine.type, "MAGAZINE")
		XCTAssertEqual(futureMagazine.magazine?.artifactId, "future-artifact")
		XCTAssertNil(futureMagazine.magazine?.imageURL)

		let futureItem = try XCTUnwrap(items.first { $0.type == "FUTURE_ITEM" })
		XCTAssertNil(futureItem.magazine)
		XCTAssertNil(futureItem.mix)
		XCTAssertNil(futureItem.album)
	}

	@MainActor
	func testMagazineUndecodablePayloadLeavesItemNil() throws {
		let json = """
		{"uuid":"x","items":[{"type":"HORIZONTAL_LIST","items":[{"type":"MAGAZINE","data":{"artifactId":"no-id"}},{"type":"MAGAZINE","data":{"id":1,"artifactId":"ok","type":"EXTURL"}}]}]}
		"""
		let feed = try JSONDecoder.custom.decode(HomeFeedV2.self, from: Data(json.utf8))
		let items = try XCTUnwrap(feed.items.first?.items)
		XCTAssertEqual(items.count, 2)
		XCTAssertNil(items[0].magazine)
		XCTAssertEqual(items[1].magazine?.artifactId, "ok")
	}

	@MainActor
	func testMagazineEncodeDecodeRoundTrip() throws {
		let json = """
		{"type":"MAGAZINE","following":false,"data":{"id":42,"imageURL":"https://resources.tidal.com/images/x/550x400.jpg","artifactId":"539430","type":"ALBUM","header":"35th ANNIVERSARY","shortHeader":"Mariah Carey","shortSubHeader":"Emotions","groupName":"EXPLORE","priority":29}}
		"""
		let item = try JSONDecoder.custom.decode(HomeFeedItem.self, from: Data(json.utf8))
		let data = try JSONEncoder().encode(item)
		let decoded = try JSONDecoder.custom.decode(HomeFeedItem.self, from: data)

		XCTAssertEqual(decoded.type, "MAGAZINE")
		XCTAssertEqual(decoded.magazine?.id, 42)
		XCTAssertEqual(decoded.magazine?.artifactId, "539430")
		XCTAssertEqual(decoded.magazine?.type, "ALBUM")
		XCTAssertEqual(decoded.magazine?.header, "35th ANNIVERSARY")
		XCTAssertEqual(decoded.magazine?.shortHeader, "Mariah Carey")
		XCTAssertEqual(decoded.magazine?.shortSubHeader, "Emotions")
		XCTAssertEqual(decoded.magazine?.groupName, "EXPLORE")
		XCTAssertEqual(decoded.magazine?.priority, 29)
		XCTAssertNotNil(decoded.magazine?.imageURL)
	}
}
