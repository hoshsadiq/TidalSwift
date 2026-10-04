//
//  TemporaryOfflineLibrary.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 04.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
@testable import TidalSwiftLib

/// A throwaway offline-library root for tests.
///
/// `Offline.init` starts a background sync that removes every audio file in the
/// library folder not present in the stored database, and tests run with an
/// empty database. Pointing a test `Session` at one of these roots keeps that
/// sync away from the developer's real `~/Music/TidalSwift Offline Library`.
final class TemporaryOfflineLibrary: Sendable {
	let root: URL

	init(label: String) {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("TidalSwiftTests-\(label)-\(UUID().uuidString)")
	}

	@MainActor
	func makeSession(config: Config? = nil) -> Session {
		// `config ?? Config(...)` is deliberate: passing `nil` straight through to
		// `Session` makes it fall back to `Config.load()`, which reads a real Tidal
		// session out of this machine's UserDefaults. A test must never sign in as
		// the developer, and that stored token is stale anyway.
		Session(config: config ?? Config(
			accessToken: "",
			refreshToken: "",
			clientID: "",
			offlineAudioQuality: .high
		), offlineLibraryRoot: root)
	}

	func remove() {
		try? FileManager.default.removeItem(at: root)
	}
}
