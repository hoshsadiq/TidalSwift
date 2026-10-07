//
//  HiResStreamCacheDirectoryTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins `HiResStreamCache.directory` itself: `pruneCache()` deletes from it, and the offline
/// library lives under `~/Music`, so a default resolving inside it would let pruning delete
/// the user's downloaded music.
final class HiResStreamCacheDirectoryTests: XCTestCase {
	func testDefaultCacheDirectoryIsNotInsideTheOfflineLibrary() {
		let cachePath = HiResStreamCache.directory.standardizedFileURL.path
		let musicPath = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Music", isDirectory: true)
			.standardizedFileURL.path

		XCTAssertFalse(
			cachePath == musicPath || cachePath.hasPrefix(musicPath + "/"),
			"the playback cache must not live inside ~/Music, where the offline library is"
		)
	}
}
