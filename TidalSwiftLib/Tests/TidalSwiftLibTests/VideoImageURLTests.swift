//
//  VideoImageURLTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

@MainActor
final class VideoImageURLTests: XCTestCase {
	private func video(imageId: String) -> Video {
		Video(
			id: 1,
			title: "Title",
			volumeNumber: 0,
			trackNumber: 0,
			releaseDate: Date(timeIntervalSince1970: 0),
			imagePath: nil,
			imageId: imageId,
			duration: 60,
			quality: "MP4_1080P",
			streamReady: true,
			streamStartDate: nil,
			allowStreaming: true,
			explicit: false,
			popularity: 0,
			type: "Music Video",
			adsUrl: nil,
			adsPrePaywallOnly: false,
			artists: []
		)
	}

	func testImageUrlWithoutResolutionYIsSquare() throws {
		let session = Session(config: nil)
		let url = try XCTUnwrap(video(imageId: "9f90d256-d419-426c-93dd-62744ed89f20")
			.imageUrl(session: session, resolution: 640))
		XCTAssertTrue(url.absoluteString.hasSuffix("/640x640.jpg"), url.absoluteString)
	}

	func testImageUrlWithResolutionYIsSixteenByNine() throws {
		let session = Session(config: nil)
		let url = try XCTUnwrap(video(imageId: "9f90d256-d419-426c-93dd-62744ed89f20")
			.imageUrl(session: session, resolution: 640, resolutionY: 360))
		XCTAssertTrue(url.absoluteString.hasSuffix("/640x360.jpg"), url.absoluteString)
	}
}
