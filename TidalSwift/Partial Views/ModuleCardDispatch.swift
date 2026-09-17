//
//  ModuleCardDispatch.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// Maps a page module and one of its items to the existing grid-item card for
/// that content type.
///
/// Cards are reused as-is. Page payloads that are tolerant subsets of the full
/// models (`PagePlaylist`, `PageMix`, `PageVideo`) are adapted through the
/// `init(page…)` initializers in `TidalSwiftLib`.
///
/// Unknown module types, and items whose payload is missing, render `EmptyView()`.
@ViewBuilder
func moduleCard(
	for item: PageItem,
	moduleType: PageModuleType,
	showReleaseDate: Bool = false,
	session: Session,
	player: Player
) -> some View {
	switch moduleType {
	case .albumList:
		card(for: .album, item: item, showReleaseDate: showReleaseDate, session: session, player: player)
	case .artistList:
		card(for: .artist, item: item, session: session, player: player)
	case .playlistList:
		card(for: .playlist, item: item, session: session, player: player)
	case .trackList:
		card(for: .track, item: item, session: session, player: player)
	case .mixList:
		card(for: .mix, item: item, session: session, player: player)
	case .videoList:
		card(for: .video, item: item, session: session, player: player)
	case .mixedTypesList:
		if let kind = item.kind {
			card(for: kind, item: item, showReleaseDate: showReleaseDate, session: session, player: player)
		}
	default:
		EmptyView()
	}
}

/// Builds the card for a concrete item kind. Shared by the typed module cases
/// and `MIXED_TYPES_LIST`, which dispatches per item.
@ViewBuilder
private func card(
	for kind: PageItemKind,
	item: PageItem,
	showReleaseDate: Bool = false,
	session: Session,
	player: Player
) -> some View {
	switch kind {
	case .album:
		if let album = item.album {
			AlbumGridItem(album: album, showArtists: true, showReleaseDate: showReleaseDate, session: session, player: player)
		}
	case .artist:
		if let artist = item.artist {
			ArtistGridItem(artist: artist, session: session, player: player)
		}
	case .playlist:
		if let playlist = item.playlist {
			PlaylistGridItem(playlist: Playlist(pagePlaylist: playlist), session: session, player: player)
		}
	case .track:
		if let track = item.track {
			TrackGridItem(track: track, showArtist: true, session: session, player: player)
		}
	case .mix:
		if let mix = item.mix {
			MixGridItem(mix: MixesItem(pageMix: mix), session: session, player: player)
		}
	case .video:
		if let video = item.video {
			VideoGridItem(video: Video(pageVideo: video), showArtist: true, session: session, player: player)
		}
	}
}
