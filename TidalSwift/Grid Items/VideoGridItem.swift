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
	/// Square-layout artwork edge length. Ignored when `wide` is set, which uses
	/// its own 16:9 card size.
	var artworkSize: CGFloat = VideoGridItem.defaultArtworkSize
	/// Opt-in wide (16:9) layout for video grids and shelves: a 16:9 thumbnail,
	/// title + artist, then `N MIN` and a `VIDEO` pill. Off by default so the
	/// square Music tab / Favourites cards are unchanged.
	var wide: Bool = false
	/// Opt-in "HD" chip overlaid on the artwork's top-leading corner, matching
	/// the Collection ▸ Videos cards. Off by default so the Music tab and
	/// Favourites grids are unchanged.
	var showsHDBadge: Bool = false

	@EnvironmentObject var playbackInfo: PlaybackInfo
	@EnvironmentObject var toastCenter: ToastCenter

	static let defaultArtworkSize: CGFloat = 160
	/// Wide (16:9) tiles use their own width, not a multiple of the square card,
	/// so they stay a normal grid size rather than an oversized hero.
	static let wideCardWidth: CGFloat = 190
	/// Padding around each card, applied on every side.
	static let cardPadding: CGFloat = 5
	private static let wideAspectRatio: CGFloat = 16.0 / 9.0

	/// Horizontal space one card occupies: its width plus the padding on each
	/// side. Grids size a column from this so a card is never clipped by a
	/// column built for a different card size.
	static func footprint(wide: Bool) -> CGFloat {
		(wide ? wideCardWidth : defaultArtworkSize) + 2 * cardPadding
	}

	private var cardWidth: CGFloat { wide ? Self.wideCardWidth : artworkSize }
	private var artworkHeight: CGFloat { wide ? cardWidth / Self.wideAspectRatio : artworkSize }

	var body: some View {
		Group {
			if wide {
				wideCard
					.padding(Self.cardPadding)
					.help("\(video.title) – \(video.artists.formArtistString())")
					.contentShape(Rectangle())
					.onTapGesture { toastCenter.show(ToastCenter.videoComingSoon) }
			} else {
				regularCard
					.padding(Self.cardPadding)
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
			}
		}
		.contextMenu {
			VideoContextMenu(video: video, session: session, player: player)
		}
	}

	private var regularCard: some View {
		VStack {
			artwork(width: artworkSize, height: artworkSize)
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
	}

	private var wideCard: some View {
		VStack(alignment: .leading, spacing: 4) {
			artwork(width: cardWidth, height: artworkHeight)
			HStack {
				Text(video.title)
					.lineLimit(1)
				if video.explicit {
					Text("􀂝")
						.foregroundColor(.secondary)
						.layoutPriority(1)
				}
			}
			.frame(width: cardWidth, alignment: .leading)
			if showArtist {
				Text(video.artists.formArtistString())
					.fontWeight(.light)
					.foregroundColor(Color.secondary)
					.lineLimit(1)
					.frame(width: cardWidth, alignment: .leading)
			}
			HStack(spacing: 6) {
				Text("\(video.duration / 60) MIN")
					.font(.caption2)
					.fontWeight(.semibold)
					.foregroundColor(.secondary)
				Text("VIDEO")
					.font(.caption2)
					.fontWeight(.semibold)
					.foregroundColor(.secondary)
					.padding(.horizontal, 5)
					.padding(.vertical, 1)
					.overlay(
						RoundedRectangle(cornerRadius: 3)
							.stroke(Color.secondary.opacity(0.6), lineWidth: 1)
					)
			}
		}
	}

	@ViewBuilder
	private func artwork(width: CGFloat, height: CGFloat) -> some View {
		Group {
			if let imageUrl = video.imageUrl(session: session, resolution: wide ? 640 : 320,
											 resolutionY: wide ? 360 : nil) {
				ArtworkImage(url: imageUrl, size: width, height: height)
			} else {
				ZStack {
					Rectangle()
						.foregroundColor(Color.secondary.opacity(0.15))
						.frame(width: width, height: height)
						.cornerRadius(CORNERRADIUS)
						.shadow(radius: SHADOWRADIUS, y: SHADOWY)
					Text(video.title)
						.foregroundColor(.primary)
						.multilineTextAlignment(.center)
						.lineLimit(2)
						.frame(width: width)
				}
			}
		}
		.overlay(alignment: .topLeading) {
			if showsHDBadge {
				Text("HD")
					.font(.caption2)
					.fontWeight(.semibold)
					.foregroundColor(.white)
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
					.padding(6)
			}
		}
	}
}
