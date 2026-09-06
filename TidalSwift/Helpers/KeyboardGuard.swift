//
//  KeyboardGuard.swift
//  TidalSwift
//

import AppKit

@MainActor enum KeyboardGuard {
	static var isTextEntryActive: Bool {
		NSApp.keyWindow?.firstResponder is NSTextView
	}
}
