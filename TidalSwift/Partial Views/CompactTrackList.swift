//
//  CompactTrackList.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// TIDAL's compact track list: a section header followed by a 3-column grid of
/// small track rows.
///
/// Used for the v2 `COMPACT_GRID_CARD` modules (e.g. "Recommended new tracks",
/// "Spotlighted Uploads"), which TIDAL renders as a 3×3 list rather than a
/// horizontal carousel. The header reuses `ShelfHeader` without the paging
/// chevrons, since nothing scrolls horizontally here.
struct CompactTrackList: View {
	let title: String
	var subtitle: String?
	var onViewAll: (() -> Void)?
	let items: [HomeFeedShelfItem]
	let session: Session
	let player: Player

	/// Only track payloads can be rendered; anything else is skipped.
	private var tracks: [HomeFeedTrack] {
		items.compactMap { $0.item.track }
	}

	private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 3)

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			ShelfHeader(
				title: title,
				subtitle: subtitle,
				onViewAll: onViewAll,
				showsScrollButtons: false
			)
			if !tracks.isEmpty {
				LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
					ForEach(tracks) { track in
						CompactTrackRow(track: track, session: session, player: player)
					}
				}
				.padding(.horizontal)
			}
		}
	}
}

/// A single compact row: small artwork, title (with the upload badge when the
/// track is an independent upload) over the artist string, and a trailing "⋯"
/// menu.
///
/// Interactions mirror the app's other track rows: double-click plays, the
/// context menu and the "⋯" button both open `TrackContextMenu`.
private struct CompactTrackRow: View {
	let track: HomeFeedTrack
	let session: Session
	let player: Player

	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var playbackInfo: PlaybackInfo

	private var sharedTrack: Track { track.asTrack }

	private var isPlaying: Bool {
		guard !queueInfo.queue.isEmpty, queueInfo.queue.indices.contains(queueInfo.currentIndex) else { return false }
		return queueInfo.queue[queueInfo.currentIndex].track == sharedTrack
	}

	var body: some View {
		HStack(spacing: 8) {
			cover
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 4) {
					Text(track.title)
						.fontWeight(.semibold)
						.lineLimit(1)
						.truncationMode(.tail)
					if track.upload == true {
						uploadBadge
					}
				}
				if let artists = track.artists, !artists.isEmpty {
					Text(artists.formArtistString())
						.font(.subheadline)
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.tail)
				}
			}
			Spacer(minLength: 4)
			Menu {
				TrackContextMenu(track: sharedTrack, session: session, player: player)
			} label: {
				Image(systemName: "ellipsis")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.secondaryIconColor()
			.help("More")
		}
		.padding(.vertical, 4)
		.background(
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(isPlaying ? Color.controlAccentColor.opacity(0.25) : .clear)
		)
		.contentShape(Rectangle())
		.foregroundColor(sharedTrack.isUnavailable || playbackInfo.failedTrackIds.contains(sharedTrack.id) ? .secondary : .primary)
		.help(toolTipString)
		.onTapGesture(count: 2) {
			guard !sharedTrack.isUnavailable else { return }
			player.add(track: sharedTrack, .now)
		}
		.contextMenu {
			TrackContextMenu(track: sharedTrack, session: session, player: player)
		}
	}

	@ViewBuilder
	private var cover: some View {
		ZStack {
			if let coverId = track.album?.cover, let coverUrl = session.imageUrl(imageId: coverId, resolution: 80) {
				ArtworkImage(url: coverUrl, size: 40, showsShadow: false)
			} else {
				Rectangle()
					.foregroundColor(.black)
			}
			if isPlaying {
				Rectangle()
					.fill(Color.black.opacity(0.45))
				Image(systemName: "play.fill")
					.foregroundColor(.white)
			}
		}
		.frame(width: 40, height: 40)
		.cornerRadius(CORNERRADIUS)
		.accessibilityHidden(true)
	}

	/// TIDAL's ↑ badge for independent uploads: a small rounded-rectangle outline
	/// around an upward arrow, in the accent/yellow tint.
	private var uploadBadge: some View {
		Image(systemName: "arrow.up")
			.font(.system(size: 8, weight: .bold))
			.foregroundColor(.yellow)
			.frame(width: 14, height: 14)
			.overlay(
				RoundedRectangle(cornerRadius: 3)
					.stroke(Color.yellow, lineWidth: 1)
			)
			.accessibilityLabel("Upload")
	}

	private var toolTipString: String {
		var s = track.title
		if let version = track.version {
			s += " (\(version))"
		}
		if let artists = track.artists, !artists.isEmpty {
			s += " – \(artists.formArtistString())"
		}
		return s
	}
}
