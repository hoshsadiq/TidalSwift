//
//  PreferencesGeneralTab.swift
//  TidalSwift
//

import SwiftUI

struct PreferencesGeneralTab: View {
	@AppStorage("SaveFavoritesOffline") public var saveFavoritesOffline = false

	var body: some View {
		Form {
			Section("General") {
				Toggle("Save Favorites Offline", isOn: $saveFavoritesOffline)
			}

			Section("Content") {
				Toggle(isOn: .constant(false)) {
					VStack(alignment: .leading) {
						Text("Allow explicit content")
							.foregroundStyle(.secondary)
						Text("When on, music labeled with the E badge will be playable. To prevent explicit music from playing, switch this off.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(true)

				Toggle(isOn: .constant(false)) {
					VStack(alignment: .leading) {
						Text("Allow AI content")
							.foregroundStyle(.secondary)
						Text("When on, music labeled with the AI badge will be playable. To prevent AI-labeled music from playing, switch this off.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(true)

				HStack {
					VStack(alignment: .leading) {
						Text("Blocked")
							.foregroundStyle(.secondary)
						Text("View and edit your blocked content.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Spacer()
					Image(systemName: "chevron.right")
						.foregroundStyle(.secondary)
				}
				.disabled(true)
			}

			Section("Connect") {
				HStack {
					VStack(alignment: .leading) {
						Text("Last.fm")
							.foregroundStyle(.secondary)
						Text("Share what music you're enjoying on TIDAL.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Spacer()
					Button("Connect") {}
						.disabled(true)
				}
				.disabled(true)
			}

			Section("Preferences") {
				Picker(selection: .constant(0)) {
					Text("English (US)").tag(0)
				} label: {
					Text("Language")
						.foregroundStyle(.secondary)
				}
				.disabled(true)

				Toggle(isOn: .constant(false)) {
					VStack(alignment: .leading) {
						Text("Startup")
							.foregroundStyle(.secondary)
						Text("Open TidalSwift automatically after you log into the computer")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(true)
			}
		}
		.formStyle(.grouped)
	}
}
