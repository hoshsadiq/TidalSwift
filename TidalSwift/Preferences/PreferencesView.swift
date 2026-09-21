//
//  PreferencesView.swift
//  TidalSwift
//

import SwiftUI
import TidalSwiftLib

struct PreferencesView: View {
	@EnvironmentObject private var appModel: TidalSwiftAppModel

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
	@EnvironmentObject private var appModel: TidalSwiftAppModel

	var body: some View {
		Form {
			Section {
				HStack {
					Button {
						if appModel.audioQuality != .low && appModel.audioQuality != .medium {
							appModel.setAudioQuality(.medium)
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
							appModel.setAudioQuality(newValue)
						}
					)) {
						Text("96 kbps").tag(AudioQuality.low)
						Text("320 kbps").tag(AudioQuality.medium)
					}
					.labelsHidden()
					.fixedSize()
				}

				Button {
					appModel.setAudioQuality(.high)
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

				Button {
					appModel.setAudioQuality(.max)
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

private extension AudioQuality {
	var shortTitle: String {
		switch self {
		case .low, .medium: "Low"
		case .high: "High"
		case .max: "Max"
		}
	}
}
