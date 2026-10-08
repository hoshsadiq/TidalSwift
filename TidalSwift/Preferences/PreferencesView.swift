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
	@AppStorage(PlaybackCachePreferences.prefetchDepthKey) private var prefetchDepth = PlaybackCachePreferences.defaultPrefetchDepth
	@AppStorage(PlaybackCachePreferences.cacheSizeBytesKey) private var cacheSizeBytes = PlaybackCachePreferences.defaultCacheBytes
	@State private var cacheUsageBytes = 0
	@AppStorage(TidalSwiftAppModel.ignoreSubscriptionLimitsKey) private var ignoreSubscriptionLimits = false
	/// `session.config` is not observable, so mirror its offline quality here.
	@State private var offlineQuality: AudioQuality?
	/// Streaming is what a user usually changes, so it is the default.
	@State private var qualityTarget: QualityTarget = .stream

	var body: some View {
		Form {
			Section {
				Picker("Quality", selection: $qualityTarget) {
					Text("Stream").tag(QualityTarget.stream)
					Text("Download").tag(QualityTarget.download)
				}
				.pickerStyle(.segmented)
				.labelsHidden()

				switch qualityTarget {
				case .stream:
					AudioQualityRows(
						selection: appModel.audioQuality,
						isAvailable: { appModel.isAudioQualityAvailable($0) },
						select: { appModel.setAudioQuality($0) }
					)
					DolbyAtmosToggle(
						title: "Prefer Dolby Atmos for streaming",
						isOn: Binding(
							get: { appModel.player.preferDolbyAtmos },
							set: { appModel.setPreferDolbyAtmos($0) }
						),
						help: "Plays the Atmos version when the track has one. Only used at High or Max quality: below that, Atmos is never played, and a track Tidal serves no stereo rendition for is skipped. A copy already on disk is played whatever this is set to, so an Atmos file you already have keeps playing with it off."
					)
				case .download:
					AudioQualityRows(
						selection: offlineQuality ?? appModel.session.config.offlineAudioQuality,
						isAvailable: { appModel.isAudioQualityAvailable($0) },
						select: { quality in
							offlineQuality = quality
							appModel.session.helpers.offline.setAudioQuality(to: quality)
						}
					)
					DolbyAtmosToggle(
						title: "Prefer Dolby Atmos for downloads",
						isOn: Binding(
							get: { offlinePreferDolbyAtmos },
							set: { newValue in
								// Set offline first so its change guard still sees the old value and resyncs.
								appModel.session.helpers.offline.setPreferDolbyAtmos(to: newValue)
								offlinePreferDolbyAtmos = newValue
							}
						),
						help: "Saves the Atmos version when the track has one. Only used at High or Max quality, so a lower quality setting never saves Atmos, and a track Tidal serves no stereo rendition for stays out of the library. A copy already on disk is played whatever this is set to, so an Atmos file you already have keeps playing with it off."
					)
				}

				Picker(selection: $prefetchDepth) {
					ForEach(PlaybackCachePreferences.prefetchDepthOptions, id: \.self) { depth in
						Text(Self.prefetchDepthLabel(depth)).tag(depth)
					}
				} label: {
					VStack(alignment: .leading) {
						Text("Prefetch tracks")
						Text("Fetches tracks ahead of the one playing. Uses disk space and bandwidth in the background.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				HStack(spacing: 8) {
					VStack(alignment: .leading) {
						Text("Cache size")
						Text("How much space prepared tracks may use, in GB. Tracks you have not played recently are removed first. Currently using \(Self.gigabyteCount(cacheUsageBytes)).")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Spacer()
					TextField("", value: cacheSizeGB, format: .number)
						.frame(width: 56)
						.multilineTextAlignment(.trailing)
					Stepper("", value: cacheSizeGB, in: PlaybackCachePreferences.cacheSizeRange)
						.labelsHidden()
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
					case .stream:
						Text("Applies to the next track you play.")
						if let highest = appModel.highestSoundQuality {
							Text("Your subscription supports up to \(highest.shortTitle).")
						}
					case .download:
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
			cacheUsageBytes = PlaybackCache.usageBytes()
		}
	}

	/// 0 is a state worth naming rather than leaving the user to infer from a number.
	private static func prefetchDepthLabel(_ depth: Int) -> String {
		switch depth {
		case 0: return "Off"
		case 1: return "Next track"
		default: return "Next \(depth) tracks"
		}
	}

	private var cacheSizeGB: Binding<Int> {
		Binding(
			get: { max(1, cacheSizeBytes / (1024 * 1024 * 1024)) },
			set: { cacheSizeBytes = $0 * 1024 * 1024 * 1024 }
		)
	}

	private static func gigabyteCount(_ bytes: Int) -> String {
		let gigabytes = Double(bytes) / Double(1024 * 1024 * 1024)
		if gigabytes >= 1 {
			return "\(Int(gigabytes.rounded())) GB"
		}
		return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
	}
}

private enum QualityTarget: Hashable {
	case stream
	case download
}

/// The Atmos preference for one target. Streaming and downloading each carry their own, so a
/// user can play Atmos while storing stereo or the reverse; the title names which one an
/// individual switch changes.
private struct DolbyAtmosToggle: View {
	let title: String
	@Binding var isOn: Bool
	let help: String

	var body: some View {
		Toggle(isOn: $isOn) {
			VStack(alignment: .leading) {
				Text(title)
				Text(help)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}
}

/// The quality tiers, shared by the streaming and offline pickers so both behave the
/// same. Every tier stays visible; one the subscription does not allow is greyed.
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

			// Greyed per option: a 320 kbps cap still shows the 96 kbps row selectable.
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

		qualityRow(title: "High", subtitle: "16-bit, 44.1 kHz", quality: .high)
		qualityRow(title: "Max", subtitle: "Up to 24-bit, 192 kHz", quality: .max)
	}

	@ViewBuilder
	private func qualityRow(title: String, subtitle: String, quality: AudioQuality) -> some View {
		let isSelected = selection == quality
		Button {
			select(quality)
		} label: {
			HStack {
				Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
					.foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
					.imageScale(.large)

				VStack(alignment: .leading) {
					Text(title)
						.foregroundStyle(.primary)
					Text(subtitle)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!isAvailable(quality))
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
