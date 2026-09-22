//
//  PlaylistGrid.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 21.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct PlaylistGrid: View {
	let playlists: [Playlist]
	let session: Session
	let player: Player
	/// Opt-in card lines and mosaic artwork, passed through to
	/// `PlaylistGridItem`. Off by default so existing grids are unchanged.
	var showCreator: Bool = false
	var showItemCount: Bool = false
	var showsMosaic: Bool = false

	var body: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))]) {
			ForEach(playlists) { playlist in
				PlaylistGridItem(playlist: playlist, session: session, player: player,
								 showCreator: showCreator, showItemCount: showItemCount, showsMosaic: showsMosaic)
			}
		}
	}
}
