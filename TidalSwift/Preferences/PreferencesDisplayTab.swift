//
//  PreferencesDisplayTab.swift
//  TidalSwift
//

import SwiftUI

struct PreferencesDisplayTab: View {
	@AppStorage("ShowCollectionInSidebar") var showCollectionInSidebar = true

	var body: some View {
		Form {
			Section {
				VStack(alignment: .leading, spacing: 4) {
					Picker("Player background", selection: .constant(0)) {
						Text("Color").tag(0)
						Text("Blur").tag(1)
					}
					.pickerStyle(.segmented)

					Text("Choose your preferred look for the player background.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.disabled(true)
				.foregroundStyle(.secondary)

				Toggle(isOn: .constant(false)) {
					VStack(alignment: .leading) {
						Text("Audio metadata")
							.foregroundStyle(.secondary)
						Text("Show additional fields (e.g. BPM) in track lists")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(true)

				Toggle(isOn: .constant(false)) {
					VStack(alignment: .leading) {
						Text("Alphanumeric keys")
							.foregroundStyle(.secondary)
						Text("Display keys in alphanumeric format")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(true)

				Toggle(isOn: $showCollectionInSidebar) {
					VStack(alignment: .leading) {
						Text("Show collection in sidebar")
							.foregroundStyle(.secondary)
						Text("Show all collection items directly in the sidebar instead of a submenu.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.formStyle(.grouped)
	}
}
