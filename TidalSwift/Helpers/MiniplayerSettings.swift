//
//  MiniplayerSettings.swift
//  TidalSwift
//

import Foundation

/// The miniplayer's two content modes. Persisted as its raw value.
enum MiniplayerMode: String {
	case artwork
	case lyrics
}

/// Persisted miniplayer state, shared between the window controller (size) and
/// the SwiftUI content (mode).
enum MiniplayerSettings {
	/// `@AppStorage` key of the active mode.
	static let modeKey = "MiniplayerMode"
	/// UserDefaults keys of the persisted window size.
	static let widthKey = "MiniplayerWindowWidth"
	static let heightKey = "MiniplayerWindowHeight"

	static let defaultSize = CGSize(width: 340, height: 340)
	static let minSize = CGSize(width: 240, height: 240)
	static let maxSize = CGSize(width: 800, height: 800)

	/// The persisted size, clamped to `minSize`/`maxSize`. Falls back to
	/// `defaultSize` when nothing has been saved yet.
	static var windowSize: CGSize {
		let defaults = UserDefaults.standard
		guard defaults.object(forKey: widthKey) != nil,
			  defaults.object(forKey: heightKey) != nil else {
			return defaultSize
		}
		return CGSize(
			width: clamp(defaults.double(forKey: widthKey), minSize.width, maxSize.width),
			height: clamp(defaults.double(forKey: heightKey), minSize.height, maxSize.height)
		)
	}

	static func saveWindowSize(_ size: CGSize) {
		let defaults = UserDefaults.standard
		defaults.set(Double(size.width), forKey: widthKey)
		defaults.set(Double(size.height), forKey: heightKey)
	}

	private static func clamp(_ value: Double, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
		min(max(value, Double(lower)), Double(upper))
	}
}
