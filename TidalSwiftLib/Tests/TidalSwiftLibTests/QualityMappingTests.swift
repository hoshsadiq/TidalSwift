//
//  QualityMappingTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Pins the quality -> file-extension mapping and the album-variant collapsing
/// rule, both of which the fork merge rewrites. The assertions below record the
/// behaviour as implemented today, including the subscription cap.
@MainActor
final class QualityMappingTests: XCTestCase {
	private let releaseDate = Date(timeIntervalSince1970: 1_700_000_000)
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "QualityMapping")

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	/// `Config.load()` reads the real "Config Information" from UserDefaults, so
	/// `Session(config: nil)` in a test would load the developer's live Tidal
	/// token and use it for the background sync `Offline.init` starts. An explicit
	/// empty config keeps the test off the developer's account, and the temporary
	/// offline root keeps the sync off the developer's real library.
	private func makeSession() -> Session {
			offlineLibrary.makeSession(config: Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: .high
		))
	}

	private func album(
		id: Int,
		quality: AudioQuality?,
		atmos: Bool = false,
		explicit: Bool? = false
	) -> Album {
		Album(
			id: id,
			title: "Real Hustla",
			duration: nil,
			streamReady: nil,
			streamStartDate: nil,
			allowStreaming: nil,
			premiumStreamingOnly: nil,
			numberOfTracks: nil,
			numberOfVideos: nil,
			numberOfVolumes: nil,
			releaseDate: releaseDate,
			copyright: nil,
			type: nil,
			version: nil,
			url: nil,
			cover: nil,
			videoCover: nil,
			explicit: explicit,
			upc: nil,
			popularity: nil,
			audioQuality: quality,
			audioModes: atmos ? [.dolbyAtmos] : [.stereo],
			artist: Artist(
				id: 1,
				name: "Ludacris",
				artistTypes: nil,
				url: nil,
				picture: nil,
				popularity: nil,
				type: nil,
				banner: nil,
				relationType: nil
			),
			artists: nil
		)
	}

	// MARK: - File extension

	func testPathExtensionForQuality() {
		let session = makeSession()
		XCTAssertEqual(session.pathExtension(for: .low), "m4a")
		XCTAssertEqual(session.pathExtension(for: .medium), "m4a")
		XCTAssertEqual(session.pathExtension(for: .high), "flac")
		XCTAssertEqual(session.pathExtension(for: .max), "flac")
	}

	func testUrlExtensionWinsOverQuality() {
		let session = makeSession()
		// An Atmos track is served as an E-AC-3 MP4, so its real extension must survive.
		let atmosURL = URL(string: "https://lgf.audio.tidal.com/mediatracks/1/2.mp4")!
		XCTAssertEqual(session.pathExtension(for: atmosURL, audioQuality: .high), "mp4")
		XCTAssertEqual(session.pathExtension(for: atmosURL, audioQuality: .max), "mp4")
	}

	func testUrlWithoutExtensionFallsBackToQuality() {
		let session = makeSession()
		let bareURL = URL(string: "https://lgf.audio.tidal.com/mediatracks/1/2")!
		XCTAssertEqual(session.pathExtension(for: bareURL, audioQuality: .high), "flac")
		XCTAssertEqual(session.pathExtension(for: bareURL, audioQuality: .low), "m4a")
	}

	// MARK: - Variant collapsing

	/// TIDAL lists one entry per variant; identical title/artist/date must collapse
	/// to a single album.
	func testVariantsCollapseToSingleAlbum() {
		let variants = [
			album(id: 1, quality: .max, explicit: true),
			album(id: 2, quality: .max, explicit: false),
			album(id: 3, quality: .high, explicit: true),
			album(id: 4, quality: .high, explicit: false),
			album(id: 5, quality: .medium, explicit: true),
			album(id: 6, quality: .low, explicit: false),
			album(id: 7, quality: .low, atmos: true, explicit: true)
		]
		let collapsed = Helpers.collapseVariants(variants, maxQuality: .max)
		XCTAssertEqual(collapsed.count, 1)
	}

	/// With no cap the highest tier wins.
	func testUncappedPrefersHighestTier() {
		let collapsed = Helpers.collapseVariants(
			[album(id: 1, quality: .high), album(id: 2, quality: .max)],
			maxQuality: nil
		)
		XCTAssertEqual(collapsed.map(\.id), [2])
	}

	/// The user's quality setting caps which copy is preferred: anything above it
	/// scores worse than a lower tier within the cap.
	func testCapExcludesQualityAboveMaxQuality() {
		let collapsed = Helpers.collapseVariants(
			[album(id: 1, quality: .max), album(id: 2, quality: .high)],
			maxQuality: .high
		)
		XCTAssertEqual(collapsed.map(\.id), [2])
	}

	/// A Dolby Atmos copy is preferred even when it sits above the user's cap,
	/// because it is not part of the stereo tier ladder.
	func testAtmosWinsRegardlessOfCap() {
		let collapsed = Helpers.collapseVariants(
			[album(id: 1, quality: .low, atmos: true), album(id: 2, quality: .max)],
			maxQuality: .low
		)
		XCTAssertEqual(collapsed.map(\.id), [1])
	}

	/// Within one tier the explicit copy is preferred, and it beats the
	/// lowest-id tie-break.
	func testExplicitWinsWithinTier() {
		let collapsed = Helpers.collapseVariants(
			[album(id: 2, quality: .high, explicit: true), album(id: 1, quality: .high, explicit: false)],
			maxQuality: .high
		)
		XCTAssertEqual(collapsed.map(\.id), [2])
	}

	/// Otherwise the lowest id wins, so the row stays stable between refreshes.
	func testLowestIdBreaksTies() {
		let collapsed = Helpers.collapseVariants(
			[album(id: 5, quality: .high), album(id: 3, quality: .high)],
			maxQuality: .high
		)
		XCTAssertEqual(collapsed.map(\.id), [3])
	}
}
