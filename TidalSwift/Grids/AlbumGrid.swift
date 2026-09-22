//
//  AlbumGrid.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 19.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct AlbumGrid: View {
	let albums: [Album]
	let showArtists: Bool
	let showReleaseDate: Bool
	let session: Session
	let player: Player
	/// Opt-in year-only release line (`2026`) instead of the full date, passed
	/// through to `AlbumGridItem`. Off by default so existing grids are unchanged.
	var showsReleaseYear: Bool = false

	var rowHeight: CGFloat = 190

	init(albums: [Album], showArtists: Bool, showReleaseDate: Bool = false, showsReleaseYear: Bool = false, session: Session, player: Player) {
		self.albums = albums
		self.showArtists = showArtists
		self.showReleaseDate = showReleaseDate
		self.showsReleaseYear = showsReleaseYear

		if showArtists {
			rowHeight += 18
		}
		if showReleaseDate {
			rowHeight += 18
		}

		self.session = session
		self.player = player
	}

	var body: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))]) {
			ForEach(albums) { album in
				AlbumGridItem(album: album, showArtists: showArtists, showReleaseDate: showReleaseDate, showsReleaseYear: showsReleaseYear, session: session, player: player)
			}
		}
	}
}
