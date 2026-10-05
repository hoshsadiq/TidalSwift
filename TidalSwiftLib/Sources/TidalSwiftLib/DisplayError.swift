//
//  DisplayError.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation
import SwiftUI

/// Set by the app at launch so library errors can reach the user. The library
/// cannot present SwiftUI itself, so the app points this at its toast centre.
/// Left `nil` (e.g. under tests) errors only print, so no UI pops up.
@MainActor
public var displayErrorHandler: (@MainActor (_ title: String, _ content: String) -> Void)?

func displayError(title: String, content: String) {
	// Without a handler (e.g. while unit testing) this stays print-only, so no
	// pop-up appears.
	if let displayErrorHandler {
		displayErrorHandler(title, content)
	} else {
		print("\(title). \(content)")
	}
}
