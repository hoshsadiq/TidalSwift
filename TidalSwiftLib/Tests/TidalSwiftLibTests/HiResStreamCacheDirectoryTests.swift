//
//  HiResStreamCacheDirectoryTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// `HiResStreamCache.directory` is the default every production call site uses, and
/// `pruneCache()` deletes from it. The offline library lives under `~/Music`, so a
/// default that resolved inside it would let cache pruning delete the user's
/// downloaded music. The cache tests pin that `prune` respects the directory it is
/// handed; this pins the default itself.
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
