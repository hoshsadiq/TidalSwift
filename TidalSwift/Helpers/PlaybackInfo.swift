//
//  PlaybackInfo.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 22.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

@Observable
final class PlaybackInfo {
	var fraction: CGFloat = 0.0
	var playbackTimeInfo: String = "0:00 / 0:00"
	var playing: Bool = false
	var volume: Float = 1.0 { didSet { hasUnsavedChanges = true } }
	var shuffle: Bool = false { didSet { hasUnsavedChanges = true } }
	var repeatState: RepeatState = .off { didSet { hasUnsavedChanges = true } }
	var pauseAfter: Bool = false { didSet { hasUnsavedChanges = true } }
	var failedTrackIds: Set<Int> = []
	/// The stream resolved for a track, tagged with the track it describes.
	/// Resolution is async, so during a track change this still names the previous
	/// track; readers must match `trackId` before describing the current track.
	var resolvedStream: ResolvedStream?

	@ObservationIgnored var hasUnsavedChanges = false

	// MARK: Now Playing drawer
	/// Whether the Now Playing drawer is expanded. Toggled by tapping the player
	/// bar's artwork/info region.
	///
	/// Collapsing deliberately leaves `activePanel` untouched so the last panel
	/// is restored when the drawer reopens.
	var isNowPlayingExpanded: Bool = false
	/// Which panel the expanded Now Playing drawer shows. Persisted to
	/// UserDefaults so it survives relaunches.
	var activePanel: NowPlayingPanel = .none { didSet { hasUnsavedChanges = true } }
	/// Whether the Now Playing drawer covers the whole window.
	var isFullscreen: Bool = false
	/// Current playback position in seconds, kept in sync by the player's
	/// periodic time observer. Drives the lyrics panel's line highlight.
	var playbackPosition: Double = 0
	/// Ambient background colour derived from the current artwork. Shared with
	/// the drawer so its panels can pick a foreground that contrasts with it.
	var ambientColor: Color = NowPlayingAmbient.fallback
}

/// The stream that actually plays for a track (not what the track could offer).
struct ResolvedStream {
	let trackId: Int
	let quality: AudioQuality
	let isDolbyAtmos: Bool
	/// The rate the stream reports, once a cached file or the loaded item supplies one.
	var sampleRate: Int?
	/// Set for the HLS stream, whose badge is read from the tier that served it since the
	/// stream itself reports no bit depth.
	var isHLS: Bool = false
}

/// Panels of the Now Playing drawer.
enum NowPlayingPanel: String, Codable {
	case none
	case similar
	case credits
	case lyrics
}

enum RepeatState: Int, CaseIterable, Codable {
	case off
	case all
	case single
}

extension CaseIterable where Self: Equatable {
    func next() -> Self {
        let all = Self.allCases
		let idx = all.firstIndex(of: self)!
        let next = all.index(after: idx)
        return all[next == all.endIndex ? all.startIndex : next]
    }
}

struct CodablePlaybackInfo: Codable {
	// PlaybackInfo
	var fraction: CGFloat
	var volume: Float
	var shuffle: Bool
	var repeatState: RepeatState
	var pauseAfter: Bool
	/// Optional so persisted data written before this field existed still decodes.
	var activePanel: NowPlayingPanel?

	// QueueInfo
	var nonShuffledQueue: [WrappedTrack]
	var queue: [WrappedTrack]
	var currentIndex: Int
	var source: QueueSource?

	var history: [WrappedTrack]
	var maxHistoryItems: Int
}
