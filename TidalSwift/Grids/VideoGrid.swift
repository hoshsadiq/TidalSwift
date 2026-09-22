//
//  VideoGrid.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 05.10.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct VideoGrid: View {
	let videos: [Video]
	let showArtists: Bool
	let session: Session
	let player: Player
	/// Opt-in wide artwork and HD chip, passed through to `VideoGridItem`. Off
	/// by default so existing grids are unchanged.
	var wide: Bool = false
	var showsHDBadge: Bool = false

	var body: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))]) {
			ForEach(videos) { video in
				VideoGridItem(video: video, showArtist: showArtists, session: session, player: player,
							  wide: wide, showsHDBadge: showsHDBadge)
			}
		}
	}
}
