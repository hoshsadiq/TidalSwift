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
			PreferencesGeneralTab()
				.tabItem {
					Label("General", systemImage: "gearshape")
				}
		}
		.frame(width: 450, height: 250)
	}
}

private struct PlaybackPreferencesTab: View {
	@EnvironmentObject private var appModel: TidalSwiftAppModel

	private var audioQualityBinding: Binding<AudioQuality> {
		Binding(
			get: { appModel.audioQuality },
			set: { appModel.setAudioQuality($0) }
		)
	}

	var body: some View {
		VStack(alignment: .leading) {
			Picker("Audio Quality", selection: audioQualityBinding) {
				ForEach(AudioQuality.allCases) { quality in
					Text(label(for: quality)).tag(quality)
				}
			}
			.pickerStyle(RadioGroupPickerStyle())

			Text("Applies to the next track you play.")
				.foregroundColor(.secondary)
		}
		.padding()
	}

	private func label(for quality: AudioQuality) -> String {
		switch quality {
		case .low: return "Low"
		case .medium: return "High"
		case .high: return "HiFi"
		case .max: return "Max"
		}
	}
}
