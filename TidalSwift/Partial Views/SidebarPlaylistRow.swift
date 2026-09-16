//
//  SidebarPlaylistRow.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 15.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct SidebarPlaylistRow: View {
	let playlist: Playlist
	let session: Session
	var isSelected: Bool = false
	var isFavorite: Bool = false

	@State private var isOffline: Bool = false

	var body: some View {
		HStack {
			artwork
			VStack(alignment: .leading) {
				Text(playlist.title)
					.fontWeight(isSelected ? .semibold : .regular)
					.lineLimit(1)
				Text("\(playlist.numberOfTracks) Tracks")
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 5)
			if isFavorite {
				Image(systemName: "heart.fill")
					.secondaryIconColor()
			}
			if isOffline {
				Image(systemName: "cloud.fill")
					.secondaryIconColor()
			}
		}
		.padding(.vertical, 2)
		.help(playlist.title)
		.task(id: playlist.uuid) {
			isOffline = await playlist.isOffline(session: session)
		}
	}

	@ViewBuilder
	private var artwork: some View {
		if let imageUrl = playlist.imageUrl(session: session, resolution: 160) {
			AsyncImage(url: imageUrl) { image in
				image.resizable().scaledToFit()
			} placeholder: {
				Rectangle()
			}
			.frame(width: 30, height: 30)
			.cornerRadius(CORNERRADIUS)
			.accessibilityHidden(true)
		} else {
			Rectangle()
				.foregroundColor(.black)
				.frame(width: 30, height: 30)
				.cornerRadius(CORNERRADIUS)
		}
	}
}
