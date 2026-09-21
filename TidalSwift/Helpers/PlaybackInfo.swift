//
//  PlaybackInfo.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 22.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import Combine
import TidalSwiftLib

final class PlaybackInfo: ObservableObject {
	@Published var fraction: CGFloat = 0.0
	@Published var playbackTimeInfo: String = "0:00 / 0:00"
	@Published var playing: Bool = false
	@Published var volume: Float = 1.0
	@Published var shuffle: Bool = false
	@Published var repeatState: RepeatState = .off
	@Published var pauseAfter: Bool = false
	@Published var failedTrackIds: Set<Int> = []

	// MARK: Now Playing drawer
	/// Whether the Now Playing drawer is expanded. Toggled by tapping the player
	/// bar's artwork/info region.
	///
	/// Collapsing deliberately leaves `activePanel` untouched so the last panel
	/// is restored when the drawer reopens.
	@Published var isNowPlayingExpanded: Bool = false
	/// Which panel the expanded Now Playing drawer shows. Persisted to
	/// UserDefaults so it survives relaunches.
	@Published var activePanel: NowPlayingPanel = .none
	/// Whether the Now Playing drawer covers the whole window.
	@Published var isFullscreen: Bool = false
	/// Current playback position in seconds, kept in sync by the player's
	/// periodic time observer. Drives the lyrics panel's line highlight.
	@Published var playbackPosition: Double = 0
	/// Ambient background colour derived from the current artwork. Shared with
	/// the drawer so its panels can pick a foreground that contrasts with it.
	@Published var ambientColor: Color = NowPlayingAmbient.fallback
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
