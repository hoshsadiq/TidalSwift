//
//  LyricsSettings.swift
//  TidalSwift
//

import Foundation

/// Lyrics-related user preferences, shared between the Preferences UI and the
/// lyrics consumers.
enum LyricsSettings {
	/// `@AppStorage` key of the LRCLIB fallback toggle (Preferences → General).
	static let useLRCLIBFallbackKey = "UseLRCLIBFallback"

	/// Whether the LRCLIB fallback is enabled. Defaults to `true` when the user
	/// has never touched the toggle, matching `@AppStorage`'s initial value.
	static var useLRCLIBFallback: Bool {
		UserDefaults.standard.object(forKey: useLRCLIBFallbackKey) as? Bool ?? true
	}
}
