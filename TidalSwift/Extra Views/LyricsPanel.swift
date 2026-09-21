//
//  LyricsPanel.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// The Lyrics panel of the expanded Now Playing drawer.
///
/// A thin wrapper around the shared `LyricsContentView`, which the miniplayer's
/// lyrics mode also uses — the fetch, highlight and auto-scroll logic lives
/// there so there is only one implementation.
struct LyricsPanel: View {
	let session: Session
	let player: Player

	var body: some View {
		LyricsContentView(session: session, player: player, style: .drawer)
	}
}
