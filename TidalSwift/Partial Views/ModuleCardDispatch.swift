//
//  ModuleCardDispatch.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 16.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// A `HomeFeedItem` paired with a stable id, since `HomeFeedItem` itself is not
/// `Identifiable`. Items without a known payload are dropped.
struct HomeFeedShelfItem: Identifiable {
	let id: String
	let item: HomeFeedItem

	init?(_ feedItem: HomeFeedItem) {
		guard let id = Self.identifier(for: feedItem) else { return nil }
		self.id = id
		self.item = feedItem
	}

	private static func identifier(for item: HomeFeedItem) -> String? {
		if let mix = item.mix { return "mix-\(mix.id)" }
		if let album = item.album { return "album-\(album.id)" }
		if let track = item.track { return "track-\(track.id)" }
		if let artist = item.artist { return "artist-\(artist.id)" }
		if let playlist = item.playlist { return "playlist-\(playlist.uuid)" }
		if let magazine = item.magazine { return "magazine-\(magazine.id)" }
		return nil
	}
}

/// Maps a v2 home-feed item to the existing grid-item card for its kind.
///
/// The v2 payloads are adapted to the shared models through the `as*`
/// accessors in `TidalSwiftLib`. Items with no payload (unknown kinds) render
/// `EmptyView()`.
@ViewBuilder
func homeFeedCard(
	for item: HomeFeedItem,
	showReleaseDate: Bool = false,
	artworkSize: CGFloat = 160,
	mixSubtitle: String? = nil,
	session: Session,
	player: Player
) -> some View {
	switch item.type {
	case "MIX":
		if let mix = item.mix {
			MixGridItem(
				mix: mixCardItem(mix, subtitle: mixSubtitle),
				session: session,
				player: player,
				artworkSize: artworkSize
			)
		}
	case "ALBUM":
		if let album = item.album {
			AlbumGridItem(album: album.asAlbum, showArtists: true, showReleaseDate: showReleaseDate, session: session, player: player, artworkSize: artworkSize)
		}
	case "ARTIST":
		if let artist = item.artist {
			ArtistGridItem(artist: artist, session: session, player: player, artworkSize: artworkSize)
		}
	case "PLAYLIST":
		if let playlist = item.playlist {
			PlaylistGridItem(playlist: playlist.asPlaylist, session: session, player: player, artworkSize: artworkSize)
		}
	case "TRACK":
		if let track = item.track {
			TrackGridItem(track: track.asTrack, showArtist: true, session: session, player: player, artworkSize: artworkSize)
		}
	case "MAGAZINE":
		if let magazine = item.magazine {
			MagazineGridItem(magazine: magazine, session: session, player: player, artworkSize: artworkSize)
		}
	default:
		EmptyView()
	}
}

/// The mix as a `MixesItem`, optionally overriding its second line. The
/// View-all page shows TIDAL's genre description there, while the Music tab's
/// shelves keep the artist list from `asMixesItem`. The text colours are
/// carried over so the override doesn't drop them.
private func mixCardItem(_ mix: HomeFeedMix, subtitle: String?) -> MixesItem {
	let base = mix.asMixesItem
	guard let subtitle else { return base }
	return MixesItem(
		id: base.id,
		title: base.title,
		subTitle: subtitle,
		graphic: base.graphic,
		images: base.images,
		mixType: base.mixType,
		titleColor: base.titleColor,
		subtitleColor: base.subtitleColor
	)
}
