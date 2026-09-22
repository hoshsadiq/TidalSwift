//
//  ArtistGrid.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 21.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct ArtistGrid: View {
	let artists: [Artist]
	let session: Session
	let player: Player
	/// Opt-in circular artwork, passed through to `ArtistGridItem`. Off by
	/// default so existing grids are unchanged.
	var circular: Bool = false

	var body: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))]) {
			ForEach(artists) { artist in
				ArtistGridItem(artist: artist, session: session, player: player, circular: circular)
			}
		}
	}
}
