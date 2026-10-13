//
//  LinkedText.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 13.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// Text that opens a destination when clicked, shared by the player bar, the
/// list rows and the queue so every inline link behaves the same.
///
/// The hit area is the text itself, so a row's own single-click, double-click,
/// right-click and focus behaviour stays intact everywhere else. It uses a tap
/// gesture rather than a `Button` because the rows manage focus themselves and a
/// button would add a keyboard-focus stop inside them.
struct LinkedText: View {
	let text: String
	let action: () -> Void

	@State private var isHovering = false

	var body: some View {
		Text(text)
			.underline(isHovering)
			.onHover { isHovering = $0 }
			.onTapGesture(perform: action)
	}
}

/// An artist credit with each name linked to its artist page, joined by the same
/// separators `formArtistString()` uses so the play bar, the rows and the queue
/// cannot drift from the plain string they replace.
struct ArtistLinks: View {
	let artists: [Artist]
	let action: (Artist) -> Void

	var body: some View {
		HStack(spacing: 0) {
			ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
				if index > 0 {
					Text(index == artists.count - 1 ? " & " : ", ")
				}
				if artist.name == "Various Artists" {
					// A credit with no page worth opening; the context menu skips
					// it as well.
					Text(artist.name)
				} else {
					LinkedText(text: artist.name) { action(artist) }
				}
			}
		}
	}
}
