//
//  CollectionEmptyState.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI

/// The empty state shared by the Collection screens.
///
/// Wraps `ContentUnavailableView` so it matches the app's existing inline empty
/// states, and adds the one thing they lack: an optional call-to-action. The
/// action is optional because some screens have nothing useful to offer (an
/// empty filter result), while others point at a TIDAL page ("View TIDAL's top
/// albums"). When present the button is a filled, prominent pill, matching the
/// screenshots.
struct CollectionEmptyState: View {
	let systemImage: String
	let message: String
	var actionTitle: String?
	var action: (() -> Void)?

	var body: some View {
		ContentUnavailableView {
			Label("", systemImage: systemImage)
		} description: {
			Text(message)
		} actions: {
			if let actionTitle, let action {
				Button(actionTitle, action: action)
					.buttonStyle(.borderedProminent)
					.controlSize(.large)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
