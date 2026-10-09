//
//  AudioQualityPolicy.swift
//  TidalSwiftLib
//

import Foundation

/// Decides which stereo tiers a subscription may pick, with no view, no storage
/// and no session, so the rule can be exercised directly.
///
/// The policy only answers "is this tier available?". It deliberately exposes no
/// function that returns a replacement tier: the chosen quality belongs to the
/// user and is never rewritten, even when it sits above the subscription cap. A
/// refused tier degrades during playback instead (see `bestAudioUrl`).
public enum AudioQualityPolicy {
	/// The stereo tiers, lowest first. This is the one place the tier order is written: the
	/// playback walk in `HLSStreaming.qualityLadder` and the v1 descending walk in `ContentUrls`
	/// are both views of it. Dolby Atmos and Sony 360 are separate renditions, not rungs on this
	/// ladder, so they never appear here.
	public nonisolated static let ladder: [AudioQuality] = [.low, .medium, .high, .max]

	/// Whether the subscription (or its override) allows this tier.
	///
	/// A missing cap keeps every tier available, so an account whose subscription
	/// could not be read is never locked out on a guess. The override makes every
	/// tier available regardless of the cap.
	public static func isAvailable(
		_ quality: AudioQuality,
		subscriptionHighest: AudioQuality?,
		ignoringLimits: Bool
	) -> Bool {
		if ignoringLimits { return true }
		guard let subscriptionHighest else { return true }
		guard let rank = ladder.firstIndex(of: quality),
			  let highestRank = ladder.firstIndex(of: subscriptionHighest) else {
			return true
		}
		return rank <= highestRank
	}
}
