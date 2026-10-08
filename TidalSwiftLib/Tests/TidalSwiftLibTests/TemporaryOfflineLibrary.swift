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
/// `Offline.init` starts a background sync that removes every audio file in the library
/// folder not present in the stored database, and tests run with an empty database, so a
/// test session must not point at the developer's real `~/Music/TidalSwift Offline Library`.
/// The instance also owns a private `UserDefaults` suite, so two test classes cannot
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

	/// A fresh `UserDefaults(suiteName:)` per call shares the same domain, so a test and the
	/// session it built read and write the same values.
	@MainActor
	var defaults: UserDefaults {
		UserDefaults(suiteName: suiteName) ?? .standard
	}

	@MainActor
	func makeSession(config: Config? = nil) -> Session {
		// `config ?? Config(...)` is deliberate: passing `nil` straight to `Session` makes it
		// fall back to `Config.load()`, which reads a real Tidal session from this machine.
		let session = Session(config: config ?? Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: .high
		), offlineLibraryRoot: root)
		session.helpers.offline.defaults = defaults
		return session
	}

	func remove() {
		try? FileManager.default.removeItem(at: root)
		UserDefaults().removePersistentDomain(forName: suiteName)
	}
}
