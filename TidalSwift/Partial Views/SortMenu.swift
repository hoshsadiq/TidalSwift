//
//  SortMenu.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI

/// The sort control used by the Collection screens.
///
/// Generic over the option type so it carries no model knowledge: the caller
/// supplies the options, a label for each, and the selection binding. Two
/// trigger styles exist because the reference screenshots use both — the grid
/// screens (Playlists, Albums, Videos, Profiles) hide sorting behind a "⋯"
/// menu, while Tracks shows the current option inline as "DATE ADDED ⌄". Both
/// styles drive the same options and selection, so a screen can switch trigger
/// without touching its sort state.
///
/// The "⋯" style nests an inline `Picker` inside the `Menu`; on macOS 14 the
/// picker's label becomes the "Sorting" submenu and its options render with a
/// checkmark on the current one, which is exactly the screenshot's behaviour.
/// The label style is a direct dropdown instead of a submenu, because the
/// screenshot's "DATE ADDED ⌄" opens the options straight away.
struct SortMenu<Option: Hashable>: View {
	/// How the menu is triggered. See the type doc for why both exist.
	enum TriggerStyle {
		/// A "⋯" button whose first item is the "Sorting" submenu.
		case ellipsis
		/// The selected option's label, uppercased, with a trailing chevron.
		case label
	}

	let options: [Option]
	let label: (Option) -> String
	@Binding var selection: Option
	var triggerStyle: TriggerStyle = .ellipsis
	/// Title of the submenu in the "⋯" style. Defaults to "Sorting" to match
	/// the screenshots.
	var title: String = "Sorting"

	var body: some View {
		switch triggerStyle {
		case .ellipsis:
			Menu {
				Picker(title, selection: $selection) {
					ForEach(options, id: \.self) { option in
						Text(label(option)).tag(option)
					}
				}
				.pickerStyle(.inline)
			} label: {
				Image(systemName: "ellipsis")
					.font(.system(size: 14, weight: .semibold))
					.frame(width: 28, height: 28)
					.contentShape(Rectangle())
			}
			// `borderlessButton` is what actually strips a `Menu`'s pull-down
			// chrome on macOS; `.buttonStyle(.plain)` leaves it in place.
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.fixedSize()
			.help(title)
		case .label:
			Menu {
				ForEach(options, id: \.self) { option in
					Button {
						selection = option
					} label: {
						if option == selection {
							Label(label(option), systemImage: "checkmark")
						} else {
							Text(label(option))
						}
					}
				}
			} label: {
				HStack(spacing: 4) {
					Text(label(selection).uppercased())
						.font(.system(size: 11, weight: .semibold))
					Image(systemName: "chevron.down")
						.font(.system(size: 9, weight: .semibold))
				}
				.foregroundColor(.secondary)
			}
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.fixedSize()
		}
	}
}
