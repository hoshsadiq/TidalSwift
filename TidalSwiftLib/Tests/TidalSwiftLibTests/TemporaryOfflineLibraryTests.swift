//
//  TemporaryOfflineLibraryTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Guards the two properties that keep the rest of the suite off this machine's
/// real account and real music folder. Both were violated once already: a test
/// session loaded the developer's stored Tidal token, and `Offline.init` started
/// a sync against `~/Music/TidalSwift Offline Library` that removes any audio
/// file it cannot find in its database.
@MainActor
final class TemporaryOfflineLibraryTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "IsolationGuard")

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	/// `Session(config: nil)` calls `Config.load()`, which reads whatever is
	/// stored under "Config Information" — a real account token on a developer
	/// machine. A test session must not carry one.
	func testSessionDoesNotUseAStoredAccount() {
		let session = offlineLibrary.makeSession()
		XCTAssertTrue(session.config.accessToken.isEmpty, "test session carries a stored access token")
		XCTAssertTrue(session.config.refreshToken.isEmpty, "test session carries a stored refresh token")
	}

	/// The offline root must be a throwaway directory, never the Music folder.
	func testOfflineRootIsTemporary() {
		let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
		XCTAssertTrue(
			offlineLibrary.root.standardizedFileURL.path.hasPrefix(temporary),
			"offline root is outside the temporary directory: \(offlineLibrary.root.path)"
		)
	}
}
