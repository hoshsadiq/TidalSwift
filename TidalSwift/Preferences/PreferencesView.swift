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
	@AppStorage(TidalSwiftAppModel.ignoreSubscriptionLimitsKey) private var ignoreSubscriptionLimits = false
	/// The offline rows read `session.config`, which is not observable, so a changed
	/// value has to be mirrored here or the selection circle would not move.
	@State private var offlineQuality: AudioQuality?

	var body: some View {
		Form {
			Section {
				AudioQualityRows(
					selection: appModel.audioQuality,
					isAvailable: { appModel.isAudioQualityAvailable($0) },
					select: { appModel.setAudioQuality($0) }
				)

				Toggle(isOn: $ignoreSubscriptionLimits) {
					VStack(alignment: .leading) {
						Text("Ignore subscription limits")
						Text("Lets you pick a tier above what your subscription reports. Tidal may refuse it, and the app reports the failure if it does.")
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

				Text("Offline quality")
				AudioQualityRows(
					selection: offlineQuality ?? appModel.session.config.offlineAudioQuality,
					isAvailable: { appModel.isAudioQualityAvailable($0) },
					select: { quality in
						offlineQuality = quality
						appModel.session.helpers.offline.setAudioQuality(to: quality)
					}
				)
				Text("Changing this re-checks your offline library and can re-download files.")
					.font(.caption)
					.foregroundStyle(.secondary)

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

/// The quality tiers, shared by the streaming and offline pickers so both look and
/// behave the same. Every tier stays visible; one the subscription does not allow is
/// greyed and unselectable unless the "Ignore subscription limits" preference is on.
private struct AudioQualityRows: View {
	let selection: AudioQuality
	let isAvailable: (AudioQuality) -> Bool
	let select: (AudioQuality) -> Void

	var body: some View {
		HStack {
			Button {
				if selection != .low && selection != .medium && isAvailable(.medium) {
					select(.medium)
				}
			} label: {
				HStack {
					Image(systemName: (selection == .low || selection == .medium) ? "largecircle.fill.circle" : "circle")
						.foregroundStyle((selection == .low || selection == .medium) ? Color.accentColor : Color.secondary)
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

			// Disabled per option, so a subscription that allows 96 kbps but not 320 kbps
			// still shows one selectable and one greyed row.
			Picker("", selection: Binding<AudioQuality>(
				get: {
					(selection == .low || selection == .medium) ? selection : .medium
				},
				set: { newValue in
					guard isAvailable(newValue) else { return }
					select(newValue)
				}
			)) {
				Text("96 kbps")
					.tag(AudioQuality.low)
					.disabled(!isAvailable(.low))
				Text("320 kbps")
					.tag(AudioQuality.medium)
					.disabled(!isAvailable(.medium))
			}
			.labelsHidden()
			.fixedSize()
		}

		Button {
			select(.high)
		} label: {
			HStack {
				Image(systemName: selection == .high ? "largecircle.fill.circle" : "circle")
					.foregroundStyle(selection == .high ? Color.accentColor : Color.secondary)
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
		.disabled(!isAvailable(.high))

		Button {
			select(.max)
		} label: {
			HStack {
				Image(systemName: selection == .max ? "largecircle.fill.circle" : "circle")
					.foregroundStyle(selection == .max ? Color.accentColor : Color.secondary)
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
		.disabled(!isAvailable(.max))
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
