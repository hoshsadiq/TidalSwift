//
//  LogoutPersistenceTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// A logout has to survive the app's own save cycle: `saveState()` runs on quit and on
/// every scene-phase change, so a logout that only deleted the stored keys was undone the
/// moment the app saved, bringing the session back.
@MainActor
final class LogoutPersistenceTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "LogoutPersistence")

	/// These are real values on a developer machine, so each test snapshots and restores them.
	private let sessionKeys = ["Config Information", "Session Information"]

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	/// It is the save after `logout()`, not the instant itself, that used to put the session back.
	func testSaveCycleAfterLogoutLeavesNothingLoadable() {
		withPreservedDefaults(sessionKeys) {
			storeLoggedInSession()
			let session = makeLoggedInSession()
			XCTAssertTrue(session.loadSession(), "precondition: the stored session loads")

			session.logout()
			XCTAssertNil(session.userId, "logout must drop the in-memory session too")

			saveCycle(session)

			XCTAssertNil(UserDefaults.standard.object(forKey: "Session Information"),
						 "a save after a logout must not write a session back")
			XCTAssertFalse(session.loadSession(), "the next launch must not find a session to load")
		}
	}

	func testSaveCycleWhileLoggedInStillPersistsTheSession() {
		withPreservedDefaults(sessionKeys) {
			storeLoggedInSession()
			let session = makeLoggedInSession()
			XCTAssertTrue(session.loadSession(), "precondition: the stored session loads")

			saveCycle(session)

			XCTAssertNotNil(UserDefaults.standard.object(forKey: "Session Information"),
							"a logged-in save must keep writing the session")
			XCTAssertTrue(session.loadSession(), "the next launch must find the session it saved")
		}
	}

	// MARK: - Helpers

	private func saveCycle(_ session: Session) {
		session.saveConfig()
		session.saveSession()
	}

	private func storeLoggedInSession() {
		UserDefaults.standard.set(["countryCode": "US", "userId": "1"], forKey: "Session Information")
		UserDefaults.standard.set([
			"accessToken": "Bearer token",
			"refreshToken": "refresh",
			"apiToken": "api",
			"offlineAudioQuality": AudioQuality.high.rawValue,
			"imageSize": "640"
		], forKey: "Config Information")
	}

	private func makeLoggedInSession() -> Session {
		offlineLibrary.makeSession(config: Config(
			accessToken: "Bearer token",
			refreshToken: "refresh",
			clientID: "",
			offlineAudioQuality: .high
		))
	}

	private func withPreservedDefaults(_ keys: [String], _ body: () -> Void) {
		let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
		defer {
			for (key, value) in saved {
				if let value {
					UserDefaults.standard.set(value, forKey: key)
				} else {
					UserDefaults.standard.removeObject(forKey: key)
				}
			}
		}
		body()
	}
}
