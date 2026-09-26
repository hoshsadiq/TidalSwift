//
//  PlaylistGridItem.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct PlaylistGridItem: View {
	let playlist: Playlist
	let session: Session
	let player: Player
	var artworkSize: CGFloat = 160
	/// Opt-in second line: the playlist's creator (e.g. `TIDAL` or artist names).
	/// Off by default so the Music tab and Favourites grids are unchanged.
	var showCreator: Bool = false
	/// Opt-in third line: the item count (`N TRACKS` / `N VIDEOS`), uppercase,
	/// small and secondary. Off by default.
	var showItemCount: Bool = false
	/// Opt-in badge overlaid on the artwork's top-left corner, e.g. `VIDEO` on
	/// Explore's video-playlist shelves. Off by default so the Music tab and
	/// Favourites grids are unchanged.
	var badge: String?
	/// Opt-in 2×2 cover mosaic (TIDAL's playlist artwork) instead of the single
	/// cover. Off by default so the Music tab and Favourites grids keep their
	/// existing single-cover artwork.
	var showsMosaic: Bool = false

	@EnvironmentObject var viewState: ViewState
	@State private var isOffline: Bool = false

	/// Video playlists are labelled by their video count, everything else by
	/// its track count, matching TIDAL's Explore shelves.
	private var itemCountLabel: String {
		playlist.numberOfVideos > 0
			? "\(playlist.numberOfVideos) VIDEOS"
			: "\(playlist.numberOfTracks) TRACKS"
	}

	/// The creator line's text: the playlist's own creator when it has one,
	/// otherwise `TIDAL`, which is how Explore's editorial playlists are
	/// credited (the page API omits a creator for them).
	private var creatorName: String {
		if let creator = playlist.creator.name, !creator.isEmpty {
			return creator
		}
		return "TIDAL"
	}

	var body: some View {
		VStack {
			ZStack(alignment: .bottomTrailing) {
				if showsMosaic {
					// The mosaic draws flat tiles; the card supplies the corner
					// radius and shadow the single-cover path gets from
					// `ArtworkImage`.
					PlaylistMosaicImage(playlistId: playlist.uuid, session: session, size: artworkSize)
						.cornerRadius(CORNERRADIUS)
						.shadow(radius: SHADOWRADIUS, y: SHADOWY)
						.contentShape(Rectangle())
						.clipped()
				} else if let imageUrl = playlist.imageUrl(session: session, resolution: 320) {
					ArtworkImage(url: imageUrl, size: artworkSize)
						.contentShape(Rectangle())
						.clipped()
				} else {
					ZStack {
						Rectangle()
							.foregroundColor(Color.secondary.opacity(0.15))
							.frame(width: artworkSize, height: artworkSize)
							.cornerRadius(CORNERRADIUS)
							.shadow(radius: SHADOWRADIUS, y: SHADOWY)
						Text(playlist.title)
							.foregroundColor(.primary)
							.multilineTextAlignment(.center)
							.lineLimit(2)
							.frame(width: artworkSize)
					}
				}
				if isOffline {
					Image(systemName: "cloud.fill")
						.resizable()
						.scaledToFit()
						.frame(width: 30)
						.foregroundStyle(.white)
						.shadow(color: .black.opacity(0.7), radius: 2, y: 1)
						.padding(5)
				}
			}
			.overlay(alignment: .topLeading) {
				if let badge {
					Text(badge)
						.font(.caption2)
						.fontWeight(.semibold)
						.textCase(.uppercase)
						.foregroundColor(.white)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
						.padding(6)
				}
			}
			Text(playlist.title)
				.lineLimit(1)
				.frame(width: artworkSize)
			if showCreator {
				Text(creatorName)
					.fontWeight(.light)
					.foregroundColor(Color.secondary)
					.lineLimit(1)
					.frame(width: artworkSize)
			}
			if showItemCount {
				Text(itemCountLabel)
					.font(.caption2)
					.fontWeight(.semibold)
					.foregroundColor(.secondary)
					.textCase(.uppercase)
					.lineLimit(1)
					.frame(width: artworkSize)
			}
		}
		.padding(5)
		.help(playlist.title)
		.onTapGesture(count: 2) {
			print("Second Click. \(playlist.title)")
			player.add(playlist: playlist, .now, source: QueueSource(type: .playlist, title: playlist.title, id: playlist.uuid))
		}
		.onTapGesture(count: 1) {
			print("First Click. \(playlist.title)")
			viewState.push(playlist: playlist)
		}
		.contextMenu {
			PlaylistContextMenu(playlist: playlist, session: session, player: player)
		}
		.task(id: playlist.uuid) {
			isOffline = await playlist.isOffline(session: session)
		}
	}
}
