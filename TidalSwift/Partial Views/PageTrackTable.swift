//
//  PageTrackTable.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// The v1 track table used by `TRACK_LIST` modules.
///
/// A `TITLE / ARTIST / TIME` header row followed by one row per track, each with
/// add-to-queue and favourite actions. Double-click plays the track, a single
/// click selects it (mirroring `TrackList`'s selection highlight).
struct PageTrackTable: View {
	let tracks: [Track]
	let session: Session
	let player: Player

	@State private var selectedTrackId: Int?

	private let coverSize: CGFloat = 40
	private let timeWidth: CGFloat = 52
	private let actionsWidth: CGFloat = 76

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			LazyVStack(spacing: 0) {
				ForEach(tracks) { track in
					PageTrackRow(
						track: track,
						session: session,
						player: player,
						coverSize: coverSize,
						timeWidth: timeWidth,
						actionsWidth: actionsWidth,
						isSelected: selectedTrackId == track.id,
						onSelect: { selectedTrackId = track.id }
					)
				}
			}
		}
		.padding(.horizontal)
	}

	private var header: some View {
		HStack(spacing: 8) {
			Color.clear
				.frame(width: coverSize, height: 1)
			Text("TITLE")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("ARTIST")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("TIME")
				.frame(width: timeWidth, alignment: .trailing)
			Color.clear
				.frame(width: actionsWidth, height: 1)
		}
		.font(.caption)
		.fontWeight(.semibold)
		.foregroundColor(.secondary)
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
	}
}

/// A single row of the v1 track table.
private struct PageTrackRow: View {
	let track: Track
	let session: Session
	let player: Player
	let coverSize: CGFloat
	let timeWidth: CGFloat
	let actionsWidth: CGFloat
	let isSelected: Bool
	let onSelect: () -> Void

	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var playbackInfo: PlaybackInfo
	@State private var isFavorite: Bool?

	private var isPlaying: Bool {
		guard !queueInfo.queue.isEmpty, queueInfo.queue.indices.contains(queueInfo.currentIndex) else { return false }
		return queueInfo.queue[queueInfo.currentIndex].track == track
	}

	var body: some View {
		HStack(spacing: 8) {
			cover
			titleColumn
				.frame(maxWidth: .infinity, alignment: .leading)
			Text(track.artists.formArtistString())
				.frame(maxWidth: .infinity, alignment: .leading)
				.help(track.artists.formArtistString())
			Text(secondsToHoursMinutesSecondsString(seconds: track.duration))
				.frame(width: timeWidth, alignment: .trailing)
				.monospacedDigit()
			actions
				.frame(width: actionsWidth)
		}
		.lineLimit(1)
		.padding(.horizontal, 8)
		.padding(.vertical, 3)
		.background(
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(rowBackground)
		)
		.contentShape(Rectangle())
		.foregroundColor(track.isUnavailable || playbackInfo.failedTrackIds.contains(track.id) ? .secondary : .primary)
		.onTapGesture(count: 2) {
			guard !track.isUnavailable else { return }
			player.add(track: track, .now)
		}
		.onTapGesture(count: 1) {
			onSelect()
		}
		.contextMenu {
			TrackContextMenu(track: track, session: session, player: player)
		}
		.onReceive(NotificationCenter.default.publisher(for: .favoriteTrackChanged)) { note in
			guard let changedTrackId = note.userInfo?["trackId"] as? Int, changedTrackId == track.id else { return }
			isFavorite = note.userInfo?["isFavorite"] as? Bool
		}
		.task(id: track.id) {
			isFavorite = await track.isInFavorites(session: session)
		}
	}

	private var rowBackground: Color {
		if isPlaying {
			return Color.controlAccentColor.opacity(0.25)
		}
		if isSelected {
			return Color.controlAccentColor.opacity(0.15)
		}
		return .clear
	}

	@ViewBuilder
	private var cover: some View {
		ZStack {
			if let coverUrl = track.getCoverUrl(session: session, resolution: 80) {
				ArtworkImage(url: coverUrl, size: coverSize, showsShadow: false)
			} else {
				Rectangle()
					.foregroundColor(.black)
					.frame(width: coverSize, height: coverSize)
					.cornerRadius(CORNERRADIUS)
			}
			if isPlaying {
				Rectangle()
					.fill(Color.black.opacity(0.45))
				Image(systemName: "play.fill")
					.foregroundColor(.white)
			}
		}
		.frame(width: coverSize, height: coverSize)
		.cornerRadius(CORNERRADIUS)
		.accessibilityHidden(true)
	}

	private var titleColumn: some View {
		HStack(spacing: 4) {
			Text(track.title)
			if let version = track.version {
				Text(version)
					.foregroundColor(.secondary)
					.layoutPriority(-1)
			}
			track.attributeHStack
				.layoutPriority(1)
			Spacer(minLength: 0)
		}
		.help(trackToolTipString)
	}

	private var actions: some View {
		HStack(spacing: 12) {
			Button {
				player.add(track: track, .last)
			} label: {
				Image(systemName: "plus")
			}
			.buttonStyle(.plain)
			.help("Add to Queue")

			Button {
				toggleFavorite()
			} label: {
				Image(systemName: (isFavorite ?? false) ? "heart.fill" : "heart")
			}
			.buttonStyle(.plain)
			.help((isFavorite ?? false) ? "Remove from Favorites" : "Add to Favorites")
		}
		.secondaryIconColor()
	}

	private func toggleFavorite() {
		Task {
			if isFavorite ?? false {
				if await session.favorites?.removeTrack(trackId: track.id) == true {
					session.helpers.offline.asyncSyncFavoriteTracks()
					isFavorite = false
					NotificationCenter.default.post(name: .favoriteTrackChanged, object: nil, userInfo: ["trackId": track.id, "isFavorite": false])
				}
			} else {
				if await session.favorites?.addTrack(trackId: track.id) == true {
					session.helpers.offline.asyncSyncFavoriteTracks()
					isFavorite = true
					NotificationCenter.default.post(name: .favoriteTrackChanged, object: nil, userInfo: ["trackId": track.id, "isFavorite": true])
				}
			}
		}
	}

	private var trackToolTipString: String {
		var s = track.title
		if let version = track.version {
			s += " (\(version))"
		}
		s += " – \(track.artists.formArtistString())"
		return s
	}
}
