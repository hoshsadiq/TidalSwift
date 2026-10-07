//
//  MetadataTagsTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the Track → AudioTags mapping. The writers are tested against hand-built
/// `AudioTags`, so a wrong album artist, explicit flag or cover mapping is invisible there.
@MainActor
final class MetadataTagsTests: XCTestCase {
	private func artist(_ name: String, id: Int = 1) -> Artist {
		Artist(
			id: id, name: name, artistTypes: nil, url: nil, picture: nil,
			popularity: nil, type: nil, banner: nil, relationType: nil
		)
	}

	private func album(
		title: String = "Embedded Album",
		numberOfTracks: Int? = nil,
		numberOfVolumes: Int? = nil,
		releaseDate: Date? = nil,
		artist: Artist? = nil,
		artists: [Artist]? = nil
	) -> Album {
		Album(
			id: 2, title: title, duration: nil, streamReady: nil, streamStartDate: nil,
			allowStreaming: nil, premiumStreamingOnly: nil, numberOfTracks: numberOfTracks,
			numberOfVideos: nil, numberOfVolumes: numberOfVolumes, releaseDate: releaseDate,
			copyright: nil, type: nil, version: nil, url: nil, cover: nil, videoCover: nil,
			explicit: false, upc: nil, popularity: nil, audioQuality: nil, audioModes: nil,
			artist: artist, artists: artists
		)
	}

	private func track(
		artists: [Artist],
		album: Album,
		version: String? = nil,
		explicit: Bool = false
	) -> Track {
		Track(
			id: 1, title: "Song", duration: 1, replayGain: 0, peak: nil,
			allowStreaming: true, streamReady: true, streamStartDate: nil, premiumStreamingOnly: nil,
			trackNumber: 3, volumeNumber: 2, version: version, popularity: 1, copyright: "(c)",
			description: nil, url: URL(string: "https://tidal.com/track/1")!, isrc: "ISRC1",
			editable: false, explicit: explicit, audioQuality: .medium, audioModes: [.stereo],
			artist: artists.first, artists: artists, album: album, mixes: nil,
			dateAdded: nil, index: nil, itemUuid: nil, bpm: nil, key: nil, keyScale: nil
		)
	}

	/// A release date formatted the way the mapping formats it, so the assertion is not
	/// coupled to the machine's time zone.
	private func formatted(_ date: Date) -> String {
		date.formatted(.iso8601.year().month().day())
	}

	func testMapsTrackFieldsAndTheFetchedAlbumDetails() throws {
		let release = try XCTUnwrap(DateComponents(calendar: .init(identifier: .gregorian), timeZone: .gmt, year: 2020, month: 5, day: 4).date)
		let built = track(
			artists: [artist("Track Artist"), artist("Guest", id: 2)],
			album: album(),
			version: "Remix",
			explicit: true
		)
		let fullAlbum = album(
			title: "Full Album",
			numberOfTracks: 12,
			numberOfVolumes: 2,
			releaseDate: release,
			artists: [artist("Album Artist", id: 3)]
		)
		let cover = Data([1, 2, 3])

		let tags = Metadata.tags(for: built, album: fullAlbum, cover: cover)

		XCTAssertEqual(tags.title, "Song (Remix)")
		XCTAssertEqual(tags.artist, "Track Artist & Guest")
		XCTAssertEqual(tags.album, "Embedded Album")
		XCTAssertEqual(tags.trackNumber, 3)
		XCTAssertEqual(tags.discNumber, 2)
		XCTAssertEqual(tags.trackTotal, 12)
		XCTAssertEqual(tags.discTotal, 2)
		XCTAssertEqual(tags.albumArtist, "Album Artist")
		XCTAssertEqual(tags.releaseDate, formatted(release))
		XCTAssertEqual(tags.copyright, "(c)")
		XCTAssertEqual(tags.isrc, "ISRC1")
		XCTAssertTrue(tags.isExplicit)
		XCTAssertEqual(tags.cover, cover)
	}

	func testWithoutAFetchedAlbumTheTotalsAndAlbumArtistStayUnset() throws {
		let release = try XCTUnwrap(DateComponents(calendar: .init(identifier: .gregorian), timeZone: .gmt, year: 2020, month: 5, day: 4).date)
		let built = track(artists: [artist("Track Artist")], album: album(releaseDate: release))

		let tags = Metadata.tags(for: built, album: nil, cover: nil)

		XCTAssertNil(tags.trackTotal)
		XCTAssertNil(tags.discTotal)
		XCTAssertNil(tags.albumArtist)
		XCTAssertNil(tags.cover)
		XCTAssertEqual(tags.releaseDate, formatted(release), "the embedded album's date is the fallback")
	}

	/// The track's own album date wins; the fetched album only fills a gap.
	func testTheEmbeddedReleaseDateWinsOverTheFetchedAlbums() throws {
		let embedded = try XCTUnwrap(DateComponents(calendar: .init(identifier: .gregorian), timeZone: .gmt, year: 2019, month: 1, day: 2).date)
		let fetched = try XCTUnwrap(DateComponents(calendar: .init(identifier: .gregorian), timeZone: .gmt, year: 2020, month: 5, day: 4).date)
		let built = track(artists: [artist("Track Artist")], album: album(releaseDate: embedded))

		let tags = Metadata.tags(for: built, album: album(releaseDate: fetched), cover: nil)

		XCTAssertEqual(tags.releaseDate, formatted(embedded))
	}

	func testEmptyArtistListsLeaveArtistAndAlbumArtistUnset() {
		let built = track(artists: [], album: album())

		let tags = Metadata.tags(for: built, album: album(artists: []), cover: nil)

		XCTAssertNil(tags.artist)
		XCTAssertNil(tags.albumArtist)
	}

	func testCompilationComesFromTheEmbeddedAlbumsVariousArtists() {
		let built = track(artists: [artist("Track Artist")], album: album(artist: artist("Various Artists")))

		let tags = Metadata.tags(for: built, album: nil, cover: nil)

		XCTAssertTrue(tags.isCompilation)
	}
}
