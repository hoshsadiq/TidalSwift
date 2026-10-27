//
//  LyricsSettings.swift
//  TidalSwift
//

import Foundation
import TidalSwiftLib

/// Lyrics-related user preferences, shared between the Preferences UI and the
/// lyrics consumers.
enum LyricsSettings {
	/// `@AppStorage` key of the LRCLIB fallback toggle (Preferences → General). Shared with the
	/// library, which reads the same value when a download embeds lyrics.
	static let useLRCLIBFallbackKey = LyricsPreferences.useLRCLIBFallbackKey

	/// Whether the LRCLIB fallback is enabled. Defaults to `true` when the user
	/// has never touched the toggle, matching `@AppStorage`'s initial value.
	static var useLRCLIBFallback: Bool {
		LyricsPreferences.useLRCLIBFallback
	}
}
