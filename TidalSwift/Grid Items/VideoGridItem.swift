//
//  VideoGridItem.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct VideoGridItem: View {
	let video: Video
	let showArtist: Bool
	let session: Session
	let player: Player
	var artworkSize: CGFloat = 160

	@EnvironmentObject var playbackInfo: PlaybackInfo

	var body: some View {
		VStack {
			if let imageUrl = video.imageUrl(session: session, resolution: 320) {
				ArtworkImage(url: imageUrl, size: artworkSize)
			} else {
				ZStack {
					Rectangle()
						.foregroundColor(Color.secondary.opacity(0.15))
						.frame(width: artworkSize, height: artworkSize)
						.cornerRadius(CORNERRADIUS)
						.shadow(radius: SHADOWRADIUS, y: SHADOWY)
					Text(video.title)
						.foregroundColor(.primary)
						.multilineTextAlignment(.center)
						.lineLimit(2)
						.frame(width: artworkSize)
				}
			}
			HStack {
				Text(video.title)
					.lineLimit(1)
				if video.explicit {
					Text("􀂝")
						.foregroundColor(.secondary)
						.layoutPriority(1)
				}
			}
			.frame(width: artworkSize)
			if showArtist {
				Text(video.artists.formArtistString())
					.fontWeight(.light)
					.foregroundColor(Color.secondary)
					.lineLimit(1)
					.frame(width: artworkSize)
			}
		}
		.padding(5)
		.help("\(video.title) – \(video.artists.formArtistString())")
		#if canImport(AppKit)
		.onTapGesture(count: 2) {
			print("Play Video: \(video.title)")
			Task {
				guard let url = await video.videoUrl(session: session) else { return }
				print(url)
				player.pause()
				let controller = VideoPlayerController(videoUrl: url, volume: playbackInfo.volume)
				controller.window?.title = "\(video.title) - \(video.artists.formArtistString())"
				controller.showWindow(nil)
			}
		}
		#endif
		.contextMenu {
			VideoContextMenu(video: video, session: session, player: player)
		}
	}
}
