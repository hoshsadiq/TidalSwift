//
//  PlaybackCacheDirectoryTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins `PlaybackCache.directory` itself: pruning deletes from it, and the offline
/// library lives under `~/Music`, so a default resolving inside it would let pruning delete
/// the user's downloaded music.
final class PlaybackCacheDirectoryTests: XCTestCase {
	func testDefaultCacheDirectoryIsNotInsideTheOfflineLibrary() {
		let cachePath = PlaybackCache.directory.standardizedFileURL.path
		let musicPath = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Music", isDirectory: true)
			.standardizedFileURL.path

		XCTAssertFalse(
			cachePath == musicPath || cachePath.hasPrefix(musicPath + "/"),
			"the playback cache must not live inside ~/Music, where the offline library is"
		)
	}
}
