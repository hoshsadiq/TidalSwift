//
//  PreferencesGeneralTab.swift
//  TidalSwift
//

import SwiftUI
import TidalSwiftLib

struct PreferencesGeneralTab: View {
	@AppStorage("SaveFavoritesOffline") public var saveFavoritesOffline = false
	@AppStorage("UseLRCLIBFallback") public var useLRCLIBFallback = true
	@AppStorage(TidalLinkHandlingPreferences.enabledKey) private var handleTidalLinks = TidalLinkHandlingPreferences.defaultEnabled

	var body: some View {
		Form {
			Section("General") {
				Toggle("Save Favorites Offline", isOn: $saveFavoritesOffline)
			}

			Section("Links") {
				Toggle(isOn: Binding(
					get: { handleTidalLinks },
					set: { newValue in
						handleTidalLinks = newValue
						// Claim or hand back `tidal://` for the new value without a relaunch.
						Task { await TidalLinkRegistration.applyCurrentRegistration() }
					}
				)) {
					VStack(alignment: .leading) {
						Text("Handle TIDAL links")
						Text("Keeps tidal:// links opening in TidalSwift, and lets the browser login return here after you sign in. When off, links open in the official TIDAL app if you have it, and login uses a device code instead.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
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

			Section("Lyrics") {
				Toggle(isOn: $useLRCLIBFallback) {
					VStack(alignment: .leading) {
						Text("Use LRCLIB when TIDAL has no timed lyrics")
						Text("Track, artist and album names are sent to lrclib.net.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
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
