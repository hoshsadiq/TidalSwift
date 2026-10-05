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

	@AppStorage("offlinePreferDolbyAtmos") private var offlinePreferDolbyAtmos = false
	/// Read through the library's key so the player sees the same value without new wiring.
	@AppStorage(HiResStreamingPreferences.enabledKey) private var hiResStereoEnabled = true
	@AppStorage(HiResStreamingPreferences.prefetchDepthKey) private var prefetchDepth = HiResStreamingPreferences.defaultPrefetchDepth
	@AppStorage(HiResStreamingPreferences.cacheSizeBytesKey) private var cacheSizeBytes = HiResStreamingPreferences.defaultCacheBytes
	/// Shown in the cache row; read once when the tab appears.
	@State private var cacheUsageBytes = 0
	@AppStorage(TidalSwiftAppModel.ignoreSubscriptionLimitsKey) private var ignoreSubscriptionLimits = false
	/// The offline rows read `session.config`, which is not observable, so a changed
	/// value has to be mirrored here or the selection circle would not move.
	@State private var offlineQuality: AudioQuality?
	/// Which target the Quality section edits. Streaming is what a user usually changes,
	/// so it is the default; the choice survives tab switches while Preferences is open.
	@State private var qualityTarget: QualityTarget = .playback

	var body: some View {
		Form {
			Section {
				Picker("Quality", selection: $qualityTarget) {
					Text("Playback").tag(QualityTarget.playback)
					Text("Offline").tag(QualityTarget.offline)
				}
				.pickerStyle(.segmented)
				.labelsHidden()

				switch qualityTarget {
				case .playback:
					AudioQualityRows(
						selection: appModel.audioQuality,
						isAvailable: { appModel.isAudioQualityAvailable($0) },
						select: { appModel.setAudioQuality($0) }
					)
					DolbyAtmosToggle(
						isOn: Binding(
							get: { appModel.player.preferDolbyAtmos },
							set: { appModel.setPreferDolbyAtmos($0) }
						),
						help: "Play the Atmos version when a track has one. Only matters when Tidal also offers stereo."
					)
				case .offline:
					AudioQualityRows(
						selection: offlineQuality ?? appModel.session.config.offlineAudioQuality,
						isAvailable: { appModel.isAudioQualityAvailable($0) },
						select: { quality in
							offlineQuality = quality
							appModel.session.helpers.offline.setAudioQuality(to: quality)
						}
					)
					DolbyAtmosToggle(
						isOn: Binding(
							get: { offlinePreferDolbyAtmos },
							set: { newValue in
								// Offline owns the stored value; set it before the local write so its
								// change guard still sees the old value and runs the resync.
								appModel.session.helpers.offline.setPreferDolbyAtmos(to: newValue)
								offlinePreferDolbyAtmos = newValue
							}
						),
						help: "Store the Atmos version when a track has one. Decides which file is saved offline."
					)
				}

				Toggle(isOn: $hiResStereoEnabled) {
					VStack(alignment: .leading) {
						Text("Hi-Res Stereo")
						Text(hiResStereoHelp)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.disabled(!appModel.session.hasHiResStereoAccess)

				Stepper(value: $prefetchDepth, in: HiResStreamingPreferences.prefetchDepthRange) {
					VStack(alignment: .leading) {
						Text("Prepare upcoming tracks")
						Text(prefetchDepthHelp)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Picker(selection: $cacheSizeBytes) {
					ForEach(HiResStreamingPreferences.cacheSizeOptions, id: \.self) { bytes in
						Text(Self.byteCount(bytes)).tag(bytes)
					}
				} label: {
					VStack(alignment: .leading) {
						Text("Cache size")
						Text("How much space prepared tracks may use. Tracks you have not played recently are removed first. Currently using \(Self.byteCount(cacheUsageBytes)).")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				Toggle(isOn: $ignoreSubscriptionLimits) {
					VStack(alignment: .leading) {
						Text("Ignore subscription limits")
						Text("Lets you pick a tier above what your subscription reports. Tidal may refuse it, and the app reports the failure if it does.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			} header: {
				Text("Quality")
			} footer: {
				VStack(alignment: .leading, spacing: 2) {
					switch qualityTarget {
					case .playback:
						Text("Applies to the next track you play.")
						if let highest = appModel.highestSoundQuality {
							Text("Your subscription supports up to \(highest.shortTitle).")
						}
					case .offline:
						Text("Changing this re-checks your offline library and can re-download files.")
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
		.task {
			await appModel.loadHighestSoundQuality()
			cacheUsageBytes = HiResStreaming.cacheUsageBytes()
		}
	}

	/// What the depth control does, in plain words. 0 is a state worth naming rather
	/// than leaving the user to infer from a number.
	private var prefetchDepthHelp: String {
		if prefetchDepth == 0 {
			return "Off. Nothing is fetched in advance, so a track may pause before it starts."
		}
		return "Fetches the next \(prefetchDepth) \(prefetchDepth == 1 ? "track" : "tracks") in your queue before you play them, so they start straight away. Uses disk space and bandwidth in the background."
	}

	private static func byteCount(_ bytes: Int) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
	}

	/// Unavailable is a state worth explaining, not a toggle that quietly does nothing.
	private var hiResStereoHelp: String {
		if appModel.session.hasHiResStereoAccess {
			return "Play the 24-bit stereo version when Tidal offers it. It comes from Tidal's desktop service and is decrypted on this Mac. Where no stereo version is served, the app plays Atmos instead."
		} else {
			return "Unavailable with this login. Log in with the desktop client to get the 24-bit stereo version; this session is served the Atmos version instead."
		}
	}
}

/// The two targets the Quality section can edit.
private enum QualityTarget: Hashable {
	case playback
	case offline
}

/// The Atmos preference for one target. Playback and offline each carry their own,
/// so a user can stream stereo while storing Atmos or the reverse. The help line says
/// what the preference can actually change, which is not the same for both.
private struct DolbyAtmosToggle: View {
	@Binding var isOn: Bool
	let help: String

	var body: some View {
		Toggle(isOn: $isOn) {
			VStack(alignment: .leading) {
				Text("Prefer Dolby Atmos")
				Text(help)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
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
