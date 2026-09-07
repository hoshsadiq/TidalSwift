//
//  NowPlayingInfoBuilder.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 06.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import MediaPlayer
import AppKit
import TidalSwiftLib

@MainActor
enum NowPlayingInfoBuilder {

	/// Builds a `[String: Any]` dict for `MPNowPlayingInfoCenter.nowPlayingInfo`.
	/// Artwork is NOT included here — caller appends it after `fetchArtwork` completes.
	/// Returns `[:]` when the queue is empty or `currentIndex` is out of range.
	static func build(player: Player, session: Session) -> [String: Any] {
		let queue = player.queueInfo.queue
		let currentIndex = player.queueInfo.currentIndex
		guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return [:] }

		let track = queue[currentIndex].track
		let fraction = player.playbackInfo.fraction

		return [
			MPMediaItemPropertyTitle: track.title,
			MPMediaItemPropertyArtist: track.artists.first?.name ?? "Unknown artist",
			MPMediaItemPropertyAlbumTitle: track.album.title,
			MPMediaItemPropertyPlaybackDuration: Double(track.duration),
			MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(track.duration) * Double(fraction),
			MPNowPlayingInfoPropertyPlaybackRate: player.playbackInfo.playing ? 1.0 : 0.0,
			MPNowPlayingInfoPropertyMediaType: MPMediaType.anyAudio.rawValue,
			MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex + 1,
			MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
		]
	}

	// MARK: - Playback State

	/// macOS does NOT infer playback state from nowPlayingInfo — it must be set explicitly.
	static func updatePlaybackState(_ state: MPNowPlayingPlaybackState) {
		MPNowPlayingInfoCenter.default().playbackState = state
	}

	static func playing() { updatePlaybackState(.playing) }
	static func paused()  { updatePlaybackState(.paused) }
	static func stopped() { updatePlaybackState(.stopped) }

	// MARK: - Artwork

	/// Fetches cover art at 320 px and wraps it in `MPMediaItemArtwork`.
	/// Returns `nil` on missing cover URL or any network/decode failure — no placeholder image used.
	static func fetchArtwork(session: Session, track: Track) async -> MPMediaItemArtwork? {
		guard let url = track.getCoverUrl(session: session, resolution: 320) else { return nil }
		guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
		guard let image = NSImage(data: data) else { return nil }
		return makeArtwork(image: image)
	}

	/// `requestHandler` runs on MediaPlayer's non-main queue — this closure MUST stay
	/// nonisolated or it traps (`dispatch_assert_queue_fail`) on first artwork read.
	nonisolated private static func makeArtwork(image: NSImage) -> MPMediaItemArtwork {
		MPMediaItemArtwork(boundsSize: image.size) { _ in image }
	}

	// MARK: - Clear

	static func clear() {
		MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
		MPNowPlayingInfoCenter.default().playbackState = .stopped
	}
}
