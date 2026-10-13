//
//  AudioQualityLabel.swift
//  TidalSwiftLib
//

import Foundation

/// The user-facing name and one-line description of an audio-quality setting.
///
/// The Control menu and the Preferences picker both read this, so the two surfaces cannot drift
/// into separate vocabularies. It uses Tidal's own words: the two lossy tiers are both "Low" and
/// are told apart by their bitrate, so no tier is named "High" twice and "HiFi" is gone. Naming
/// what was actually served is a different job and stays in `HLSStreaming.badge(for:)`.
public struct AudioQualityLabel: Equatable {
	/// The setting name. The two lossy tiers share "Low"; every other tier has its own.
	public let name: String
	/// The one-line description of what the tier is.
	public let detail: String
	/// The bitrate shown for a lossy tier, and `nil` for a lossless one.
	public let bitrate: String?

	/// The text for a tier inside its group: the bitrate for a lossy tier, the name otherwise.
	public var optionLabel: String { bitrate ?? name }
}

extension AudioQuality {
	/// The name and description this tier is shown under, in Tidal's vocabulary.
	public var label: AudioQualityLabel {
		switch self {
		case .low:
			AudioQualityLabel(name: "Low", detail: "Balance audio quality and data consumption", bitrate: "96 kbps")
		case .medium:
			AudioQualityLabel(name: "Low", detail: "Balance audio quality and data consumption", bitrate: "320 kbps")
		case .high:
			AudioQualityLabel(name: "High", detail: "16-bit, 44.1 kHz", bitrate: nil)
		case .max:
			AudioQualityLabel(name: "Max", detail: "Up to 24-bit, 192 kHz", bitrate: nil)
		}
	}
}
