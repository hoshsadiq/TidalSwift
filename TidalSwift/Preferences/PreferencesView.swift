//
//  PreferencesView.swift
//  TidalSwift
//

import SwiftUI
import TidalSwiftLib

struct PreferencesView: View {
	@Environment(TidalSwiftAppModel.self) private var appModel

	var body: some View {
		TabView {
			PlaybackPreferencesTab()
				.tabItem {
					Label("Playback", systemImage: "speaker.wave.3")
				}
			PreferencesDisplayTab()
				.tabItem {
					Label("Display", systemImage: "paintbrush.pointed")
				}
			PreferencesGeneralTab()
				.tabItem {
					Label("General", systemImage: "gearshape")
				}
		}
		.frame(width: 520, height: 600)
	}
}

private struct PlaybackPreferencesTab: View {
	@Environment(TidalSwiftAppModel.self) private var appModel

	@AppStorage("offlinePreferDolbyAtmos") private var preferDolbyAtmos = false
	@AppStorage("allowMaxAudioQuality") private var allowMaxAudioQuality = false

	/// Preferences is the only place the offline quality can be changed after login,
	/// so the choice has to reach the offline layer too, not just the player.
	private func setAudioQuality(_ audioQuality: AudioQuality) {
		appModel.setAudioQuality(audioQuality)
		appModel.session.helpers.offline.setAudioQuality(to: audioQuality)
	}

	var body: some View {
		Form {
			Section {
				HStack {
					Button {
						if appModel.audioQuality != .low && appModel.audioQuality != .medium {
							setAudioQuality(.medium)
						}
					} label: {
						HStack {
							Image(systemName: (appModel.audioQuality == .low || appModel.audioQuality == .medium) ? "largecircle.fill.circle" : "circle")
								.foregroundStyle((appModel.audioQuality == .low || appModel.audioQuality == .medium) ? Color.accentColor : Color.secondary)
								.imageScale(.large)

							VStack(alignment: .leading) {
								Text("Low")
									.foregroundStyle(.primary)
								Text("Balance audio quality and data consumption")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
						}
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)

					Picker("", selection: Binding<AudioQuality>(
						get: {
							(appModel.audioQuality == .low || appModel.audioQuality == .medium) ? appModel.audioQuality : .medium
						},
						set: { newValue in
							setAudioQuality(newValue)
						}
					)) {
						Text("96 kbps").tag(AudioQuality.low)
						Text("320 kbps").tag(AudioQuality.medium)
					}
					.labelsHidden()
					.fixedSize()
				}

				Button {
					setAudioQuality(.high)
				} label: {
					HStack {
						Image(systemName: appModel.audioQuality == .high ? "largecircle.fill.circle" : "circle")
							.foregroundStyle(appModel.audioQuality == .high ? Color.accentColor : Color.secondary)
							.imageScale(.large)

						VStack(alignment: .leading) {
							Text("High")
								.foregroundStyle(.primary)
							Text("16-bit, 44.1 kHz")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.disabled(!appModel.isAudioQualityAvailable(.high))

				// Max stays hidden unless the option below is on, but an active Max choice
				// has to remain visible so the selection never becomes invisible.
				if allowMaxAudioQuality || appModel.audioQuality == .max {
					Button {
						setAudioQuality(.max)
					} label: {
						HStack {
							Image(systemName: appModel.audioQuality == .max ? "largecircle.fill.circle" : "circle")
								.foregroundStyle(appModel.audioQuality == .max ? Color.accentColor : Color.secondary)
								.imageScale(.large)

							VStack(alignment: .leading) {
								Text("Max")
									.foregroundStyle(.primary)
								Text("Up to 24-bit, 192 kHz")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
						}
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.disabled(!appModel.isAudioQualityAvailable(.max))
				}

				Toggle(isOn: $allowMaxAudioQuality) {
					VStack(alignment: .leading) {
						Text("Show Max option")
						Text("True 24-bit audio is not reachable through the endpoints this app uses, so a Max request is downgraded to 16-bit / 44.1 kHz.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			} header: {
				Text("Audio quality")
			} footer: {
				VStack(alignment: .leading, spacing: 2) {
					Text("Applies to the next track you play.")
					if let highest = appModel.highestSoundQuality {
						Text("Your subscription supports up to \(highest.shortTitle).")
					}
				}
			}

			Section("Playback") {
				Toggle(isOn: Binding(
					get: { preferDolbyAtmos },
					set: { newValue in
						// Offline owns the stored value; set it before the local write so its
						// change guard still sees the old value and runs the resync.
						appModel.session.helpers.offline.setPreferDolbyAtmos(to: newValue)
						preferDolbyAtmos = newValue
					}
				)) {
					VStack(alignment: .leading) {
						Text("Prefer Dolby Atmos")
						Text("Use the Atmos version when a track has one, even if a stereo version exists.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Toggle(isOn: .constant(false)) {
					VStack(alignment: .leading) {
						Text("Normalize volume")
							.foregroundStyle(.secondary)
						Text("Set the same volume level for all tracks.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(true)

				Picker(selection: .constant(0)) {
					Text("System Default").tag(0)
				} label: {
					Text("Sound output")
						.foregroundStyle(.secondary)
				}
				.disabled(true)

				Toggle(isOn: .constant(false)) {
					VStack(alignment: .leading) {
						Text("Autoplay")
							.foregroundStyle(.secondary)
						Text("Keep playing similar content when your queue ends.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(true)
			}
		}
		.formStyle(.grouped)
		.task { await appModel.loadHighestSoundQuality() }
	}
}

extension AudioQuality {
	fileprivate var shortTitle: String {
		switch self {
		case .low, .medium: "Low"
		case .high: "High"
		case .max: "Max"
		}
	}
}
