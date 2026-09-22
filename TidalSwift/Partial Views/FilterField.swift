//
//  FilterField.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import AppKit
import SwiftUI

/// The in-page filter field used by the Collection screens.
///
/// Presentation and binding only: it never filters anything itself, so the
/// caller keeps ownership of the matching rule (case-insensitive over title,
/// artist, album, …). Clearing always writes `""` back through the binding so
/// the caller's filter resets in one place rather than the field holding a
/// second copy of the query.
struct FilterField: View {
	let placeholder: String
	@Binding var text: String

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass")
				.font(.system(size: 12, weight: .medium))
				.foregroundColor(.secondary)
			TextField(placeholder, text: $text)
				.textFieldStyle(.plain)
				.font(.system(size: 13))
			if !text.isEmpty {
				Button {
					text = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 12))
						.foregroundColor(.secondary)
				}
				.buttonStyle(.plain)
				.help("Clear filter")
			}
		}
		.padding(.horizontal, 8)
		.frame(height: 28)
		.frame(maxWidth: .infinity)
		.background(
			RoundedRectangle(cornerRadius: 6)
				.fill(Color(nsColor: .controlBackgroundColor))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 6)
				.strokeBorder(Color.primary.opacity(0.08))
		)
	}
}
