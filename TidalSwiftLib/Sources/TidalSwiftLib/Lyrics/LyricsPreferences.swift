//
//  LyricsPreferences.swift
//  TidalSwiftLib
//

import Foundation

/// The lyrics preference the library and the app both read.
///
/// A download embeds lyrics under the same precedence the panel uses, so the setting has to
/// be readable from the library, which has no access to the app's settings types.
public nonisolated enum LyricsPreferences {
	/// The stored key is shared with the Preferences toggle, so both read one value.
	public static let useLRCLIBFallbackKey = "UseLRCLIBFallback"

	/// Whether the LRCLIB fallback is enabled. Defaults to `true` when the user has never
	/// touched the toggle, matching the toggle's own initial value.
	public static var useLRCLIBFallback: Bool {
		UserDefaults.standard.object(forKey: useLRCLIBFallbackKey) as? Bool ?? true
	}
}
