//
//  TemporaryOfflineLibrary.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
@testable import TidalSwiftLib

/// A throwaway offline-library root and defaults suite for tests.
///
/// `Offline.init` starts a background sync that removes every audio file in the
/// library folder not present in the stored database, and tests run with an
/// empty database. Pointing a test `Session` at one of these roots keeps that
/// sync away from the developer's real `~/Music/TidalSwift Offline Library`.
///
/// The same instance also owns a private `UserDefaults` suite, so the offline
/// database and preferences a test writes live there rather than in the shared
/// standard domain. Two test classes running in parallel therefore cannot see or
/// clobber each other's offline state.
final class TemporaryOfflineLibrary: Sendable {
	let root: URL
	let suiteName: String

	init(label: String) {
		let id = UUID().uuidString
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("TidalSwiftTests-\(label)-\(id)")
		suiteName = "TidalSwiftTests-\(label)-\(id)"
	}

	/// The throwaway defaults suite this library's session writes to. A fresh
	/// `UserDefaults(suiteName:)` per call shares the same domain, so a test and
	/// the session it built read and write the same values.
	@MainActor
	var defaults: UserDefaults {
		UserDefaults(suiteName: suiteName) ?? .standard
	}

	@MainActor
	func makeSession(config: Config? = nil) -> Session {
		// `config ?? Config(...)` is deliberate: passing `nil` straight through to
		// `Session` makes it fall back to `Config.load()`, which reads a real Tidal
		// session out of this machine's UserDefaults. A test must never sign in as
		// the developer, and that stored token is stale anyway.
		let session = Session(config: config ?? Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: .high
		), offlineLibraryRoot: root)
		// Redirect the offline store before the launch task touches the database,
		// so the test writes the suite instead of the test runner's standard domain.
		session.helpers.offline.defaults = defaults
		return session
	}

	func remove() {
		try? FileManager.default.removeItem(at: root)
		// Drop the suite so a later test with the same label starts empty.
		UserDefaults().removePersistentDomain(forName: suiteName)
	}
}
