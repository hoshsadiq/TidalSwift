//
//  SettingsWindow.swift
//  TidalSwift
//

import AppKit

/// SwiftUI's `Settings` scene window exposes no handle of its own, so the key
/// monitors and the Escape handler find it by its private identifier.
@MainActor enum SettingsWindow {
	static let identifier = "com_apple_SwiftUI_Settings_window"

	/// Whether the settings window is the window receiving keys.
	static var isKeyWindow: Bool {
		NSApp.keyWindow?.identifier?.rawValue == identifier
	}

	/// Closes the settings window the way Cmd-W does, leaving it reopenable from
	/// the app menu. Assumes it is the key window.
	static func close() {
		NSApp.keyWindow?.performClose(nil)
	}
}
