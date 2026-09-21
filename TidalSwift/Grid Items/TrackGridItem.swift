//
//  TrackGridItem.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct TrackGridItem: View {
	let track: Track
	let showArtist: Bool
	let session: Session
	let player: Player
	var artworkSize: CGFloat = 160

	var body: some View {
		VStack {
			if let coverUrl = track.album.getCoverUrl(session: session, resolution: 320) {
				ArtworkImage(url: coverUrl, size: artworkSize, showsShadow: false)
			} else {
				ZStack {
					Rectangle()
						.foregroundColor(Color.secondary.opacity(0.15))
						.frame(width: artworkSize, height: artworkSize)
					Text(track.title)
						.foregroundColor(.primary)
						.multilineTextAlignment(.center)
						.lineLimit(5)
						.frame(width: artworkSize)
				}
			}
			HStack {
				Text(track.title)
				if let version = track.version {
					Text(version)
						.foregroundColor(.secondary)
						.padding(.leading, -5)
				}
				track.attributeHStack
					.padding(.leading, -5)
					.layoutPriority(1)
			}
			.lineLimit(1)
			.frame(width: artworkSize)
			if showArtist {
				Text(track.artists.formArtistString())
					.fontWeight(.light)
					.foregroundColor(Color.secondary)
					.lineLimit(1)
					.frame(width: artworkSize)
					.padding(.top, track.hasAttributes ? -6.5 : 0)
			}
		}
		.padding(5)
		.help(toolTipString)
		.onTapGesture(count: 2) {
			print("\(track.title)")
			player.add(track: track, .now)
		}
		.contextMenu {
			TrackContextMenu(track: track, session: session, player: player)
		}
	}

	var toolTipString: String {
		var s = track.title
		if let version = track.version {
			s += " (\(version))"
		}
		s += track.artists.formArtistString()
		return s
	}
}

extension Track {
	var attributeHStack: some View {
		HStack {
			if explicit {
				Image(systemName: "e.square")
			}
			if audioQuality == .max {
				Image(systemName: "m.square.fill")
			}
			if audioModes?.contains(.sony360RealityAudio) ?? false {
				Image(systemName: "headphones")
			}
			if audioModes?.contains(.dolbyAtmos) ?? false {
				Image(systemName: "hifispeaker.fill")
			}
		}
		.secondaryIconColor()
	}

	var hasAttributes: Bool {
		explicit ||
			audioQuality == .max ||
			audioModes?.contains(.sony360RealityAudio) ?? false ||
			audioModes?.contains(.dolbyAtmos) ?? false
	}

	// TODO: tracks carrying DOLBY_ATMOS or SONY_360RA are refused even when they
	// also have a playable STEREO stream. Narrow this to require STEREO so
	// dual-mode tracks play.
	var isUnavailable: Bool {
		!streamReady ||
		audioModes?.contains(.sony360RealityAudio) ?? false ||
			audioModes?.contains(.dolbyAtmos) ?? false
	}
}
