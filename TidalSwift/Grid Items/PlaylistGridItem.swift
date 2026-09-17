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

	@EnvironmentObject var viewState: ViewState
	@State private var isOffline: Bool = false

	var body: some View {
		VStack {
			ZStack(alignment: .bottomTrailing) {
				if let imageUrl = playlist.imageUrl(session: session, resolution: 320) {
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
						.shadow(radius: SHADOWRADIUS)
						.padding(5)
				}
			}
			Text(playlist.title)
				.lineLimit(1)
				.frame(width: artworkSize)
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
