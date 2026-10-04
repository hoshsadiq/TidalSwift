//
//  ArtistGridItem.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct ArtistGridItem: View {
	let artist: Artist
	let session: Session
	let player: Player
	var artworkSize: CGFloat = 160
	/// Opt-in circular artwork with the name centred below (Explore's Top
	/// Artists). Off by default so the square Music tab / Favourites cards are
	/// unchanged.
	var circular: Bool = false

	@Environment(ViewState.self) private var viewState

	var body: some View {
		VStack {
			artwork
			Text(artist.name)
				.lineLimit(1)
				.frame(width: artworkSize)
		}
		.padding(5)
		.help(artist.name)
		.onTapGesture(count: 2, perform: play)
		.onTapGesture(count: 1, perform: open)
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityAction(.default, open)
		.accessibilityAction(named: "Play", play)
		.contextMenu {
			ArtistContextMenu(artist: artist, session: session, player: player)
		}
	}

	private func open() {
		print("First Click. \(artist.name)")
		viewState.push(artist: artist)
	}

	private func play() {
		print("\(artist.name)")
		player.add(artist: artist, .now, source: QueueSource(type: .artist, title: artist.name, id: String(artist.id)))
	}

	@ViewBuilder
	private var artwork: some View {
		if let pictureUrl = artist.pictureUrl(session: session, resolution: 320) {
			ArtworkImage(
				url: pictureUrl,
				size: artworkSize,
				cornerRadius: circular ? artworkSize / 2 : CORNERRADIUS
			)
		} else {
			ZStack {
				Rectangle()
					.foregroundColor(Color.secondary.opacity(0.15))
					.frame(width: artworkSize, height: artworkSize)
					.cornerRadius(circular ? artworkSize / 2 : CORNERRADIUS)
					.shadow(radius: SHADOWRADIUS, y: SHADOWY)
				Text(artist.name)
					.foregroundColor(.primary)
					.multilineTextAlignment(.center)
					.lineLimit(5)
					.frame(width: artworkSize)
			}
		}
	}
}
