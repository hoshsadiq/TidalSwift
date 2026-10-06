//
//  LogoutPersistenceTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// A logout has to survive the app's own save cycle. `saveState()` runs
/// `saveConfig()` and `saveSession()` on quit and on every scene-phase change, so a
/// logout that only deleted the stored keys was undone the moment the app saved:
/// "Session Information" came back with the old ids and the next launch's
/// `loadSession()` reported a session with no token behind it — and offline, the
/// failing `/oauth2/me` kept the session, so the login sheet never appeared.
@MainActor
final class LogoutPersistenceTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "LogoutPersistence")

	/// The keys a logout owns. On a developer machine these are real values, so each
	/// test snapshots and restores them. The offline database a test session's sync
	/// writes lives in the session's throwaway suite, not here.
	private let sessionKeys = ["Config Information", "Session Information"]

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	/// A save cycle after a logout must write nothing that `loadSession` accepts. The
	/// existing logout test only looks at the instant after `logout()`; it is the
	/// next save that used to put the session back.
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

	/// The guard that keeps the save quiet must not break the real thing: while a token
	/// is held, `saveSession` still writes the ids the next launch loads.
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

	/// What `saveState` does, on the quit path and on every scene-phase change.
	private func saveCycle(_ session: Session) {
		session.saveConfig()
		session.saveSession()
	}

	/// Exactly what a real logged-in session leaves in UserDefaults.
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
