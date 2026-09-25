//
//  PageCardDispatch.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// A `PageItem` paired with a stable id, since `PageItem` is not `Identifiable`.
///
/// The expected kind comes from the module's type: an album payload also
/// satisfies the tolerant `PageVideo` decoder (both only require `id` + `title`),
/// so `PageItem.kind` alone can't tell albums and videos apart. Items without
/// the expected payload are dropped.
struct PageShelfItem: Identifiable {
	let id: String
	let item: PageItem

	init?(_ item: PageItem, kind: PageItemKind?) {
		guard let id = Self.identifier(for: item, kind: kind ?? item.kind) else { return nil }
		self.id = id
		self.item = item
	}

	private static func identifier(for item: PageItem, kind: PageItemKind?) -> String? {
		switch kind {
		case .track:
			return item.track.map { "track-\($0.id)" }
		case .album:
			return item.album.map { "album-\($0.id)" }
		case .artist:
			return item.artist.map { "artist-\($0.id)" }
		case .playlist:
			return item.playlist.map { "playlist-\($0.uuid)" }
		case .video:
			return item.video.map { "video-\($0.id)" }
		case .mix:
			return item.mix.map { "mix-\($0.id)" }
		case nil:
			return nil
		}
	}
}

/// Maps a v1 page item to the card for its kind, opting into the v1 card
/// features added for the Explore pages: playlist creator + item count, the
/// circular artist artwork and the wide video layout. Mirrors `homeFeedCard`
/// for the v2 feed.
///
/// `kind` is the module's expected item kind and wins over the item's own
/// `kind`, which is ambiguous for albums and videos (see `PageShelfItem`).
/// Items with no payload (unknown kinds, link tiles) render `EmptyView()`.
///
/// Mix cards get a heart when `onToggleMixHeart` is set, reading its state from
/// `collectionMixIds`: TIDAL lets mixes be added to the collection from any
/// page that lists them, not just Collection ▸ Mixes.
@ViewBuilder
func pageCard(
	for item: PageItem,
	kind: PageItemKind? = nil,
	artworkSize: CGFloat = 160,
	collectionMixIds: Set<String> = [],
	onToggleMixHeart: ((MixesItem) -> Void)? = nil,
	session: Session,
	player: Player
) -> some View {
	switch kind ?? item.kind {
	case .playlist:
		playlistCard(item.playlist, artworkSize: artworkSize, session: session, player: player)
	case .album:
		albumCard(item.album, artworkSize: artworkSize, session: session, player: player)
	case .artist:
		artistCard(item.artist, artworkSize: artworkSize, session: session, player: player)
	case .video:
		videoCard(item.video, session: session, player: player)
	case .mix:
		mixCard(item.mix, artworkSize: artworkSize, collectionMixIds: collectionMixIds, onToggleMixHeart: onToggleMixHeart, session: session, player: player)
	case .track:
		trackCard(item.track, artworkSize: artworkSize, session: session, player: player)
	case nil:
		EmptyView()
	}
}

@ViewBuilder
private func playlistCard(_ playlist: PagePlaylist?, artworkSize: CGFloat, session: Session, player: Player) -> some View {
	if let playlist {
		PlaylistGridItem(
			playlist: Playlist(pagePlaylist: playlist),
			session: session,
			player: player,
			artworkSize: artworkSize,
			showCreator: true,
			showItemCount: true,
			badge: (playlist.numberOfVideos ?? 0) > 0 ? "VIDEO" : nil
		)
	}
}

@ViewBuilder
private func albumCard(_ album: Album?, artworkSize: CGFloat, session: Session, player: Player) -> some View {
	if let album {
		AlbumGridItem(
			album: album,
			showArtists: true,
			showReleaseDate: true,
			session: session,
			player: player,
			artworkSize: artworkSize
		)
	}
}

@ViewBuilder
private func artistCard(_ artist: Artist?, artworkSize: CGFloat, session: Session, player: Player) -> some View {
	if let artist {
		ArtistGridItem(
			artist: artist,
			session: session,
			player: player,
			artworkSize: artworkSize,
			circular: true
		)
	}
}

@ViewBuilder
private func videoCard(_ video: PageVideo?, session: Session, player: Player) -> some View {
	if let video {
		VideoGridItem(
			video: Video(pageVideo: video),
			showArtist: true,
			session: session,
			player: player,
			wide: true
		)
	}
}

@ViewBuilder
private func mixCard(_ mix: PageMix?, artworkSize: CGFloat, collectionMixIds: Set<String>, onToggleMixHeart: ((MixesItem) -> Void)?, session: Session, player: Player) -> some View {
	if let mix {
		let item = MixesItem(pageMix: mix)
		MixGridItem(
			mix: item,
			session: session,
			player: player,
			artworkSize: artworkSize,
			showsHeart: onToggleMixHeart != nil,
			heartIsOn: collectionMixIds.contains(item.id),
			onToggleHeart: onToggleMixHeart.map { handler in { handler(item) } }
		)
	}
}

@ViewBuilder
private func trackCard(_ track: Track?, artworkSize: CGFloat, session: Session, player: Player) -> some View {
	if let track {
		TrackGridItem(
			track: track,
			showArtist: true,
			session: session,
			player: player,
			artworkSize: artworkSize
		)
	}
}

/// Renders a single v1 page module.
///
/// The module's `type` decides the layout. Text blocks, link grids/pill rows
/// and the featured hero come from the Explore-hub components; the list types
/// use the shared `Shelf` with `pageCard`. Unknown types render nothing —
/// `PageView` logs them.
struct PageModuleContent: View {
	let module: PageModule
	let session: Session
	let player: Player

	var body: some View {
		switch module.knownType {
		case .textBlock:
			if let text = module.text, !text.isEmpty {
				TextBlock(text: text)
			}
		case .pageLinks:
			PageLinkGrid(module: module)
		case .pageLinksCloud:
			PageLinkPills(module: module)
		case .playlistList:
			PageShelfView(module: module, kind: .playlist, session: session, player: player)
		case .albumList:
			PageShelfView(module: module, kind: .album, session: session, player: player)
		case .artistList:
			PageShelfView(module: module, kind: .artist, session: session, player: player)
		case .mixList:
			PageShelfView(module: module, kind: .mix, session: session, player: player)
		case .videoList:
			PageVideoShelfView(module: module, session: session, player: player)
		case .trackList:
			PageTrackSectionView(module: module, session: session, player: player)
		case .featuredPromotions, .multipleTopPromotions:
			FeaturedHero(module: module, session: session, player: player)
		default:
			EmptyView()
		}
	}
}

/// The items of a module, from either its paged list or its inline items.
func pageModuleItems(_ module: PageModule) -> [PageItem] {
	module.pagedList?.items ?? module.items ?? []
}

/// A module's `description` as a shelf subtitle, when it carries one.
private func pageSubtitle(_ module: PageModule) -> String? {
	guard let description = module.description, !description.isEmpty else { return nil }
	return description
}

/// The module's "View all" action, when it carries a `showMore` link.
private func pageViewAllAction(_ module: PageModule, _ viewState: ViewState) -> (() -> Void)? {
	guard let showMore = module.showMore else { return nil }
	return {
		viewState.push(page: PageTarget(path: showMore.apiPath, title: module.title ?? showMore.title ?? ""))
	}
}

/// A shelf of v1 cards: playlists, albums, artists or mixes. "View all" is
/// shown only when the module carries a `showMore` link.
private struct PageShelfView: View {
	let module: PageModule
	let kind: PageItemKind
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@State private var collectionMixIds: Set<String> = []

	private var items: [PageShelfItem] {
		pageModuleItems(module).compactMap { PageShelfItem($0, kind: kind) }
	}

	var body: some View {
		Shelf(
			title: module.title ?? "",
			subtitle: pageSubtitle(module),
			onViewAll: pageViewAllAction(module, viewState),
			items: items,
			cardsPerPage: 4
		) { item, cardWidth in
			pageCard(
				for: item.item,
				kind: kind,
				artworkSize: max(1, cardWidth - 10),
				collectionMixIds: collectionMixIds,
				onToggleMixHeart: { viewState.toggleMixInCollection($0) },
				session: session,
				player: player
			)
		}
		.task {
			guard kind == .mix else { return }
			await viewState.ensureCollectionMixesLoaded()
			refreshCollectionMixIds()
		}
		.onReceive(NotificationCenter.default.publisher(for: .collectionMixChanged)) { _ in
			refreshCollectionMixIds()
		}
	}

	private func refreshCollectionMixIds() {
		guard kind == .mix else { return }
		collectionMixIds = Set(viewState.cache.collectionMixes?.map(\.id) ?? [])
	}
}

/// A shelf of wide video cards. `VideoGridItem`'s wide layout is a fixed 16:9
/// tile with 5pt padding on each side, so the shelf footprint has to match for
/// the paging maths to stay correct.
private struct PageVideoShelfView: View {
	let module: PageModule
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	private static let cardFootprint = VideoGridItem.footprint(wide: true)

	private var items: [PageShelfItem] {
		pageModuleItems(module).compactMap { PageShelfItem($0, kind: .video) }
	}

	var body: some View {
		Shelf(
			title: module.title ?? "",
			subtitle: pageSubtitle(module),
			onViewAll: pageViewAllAction(module, viewState),
			items: items,
			cardWidth: Self.cardFootprint
		) { item, _ in
			pageCard(for: item.item, kind: .video, session: session, player: player)
		}
	}
}

/// A `TRACK_LIST` module: the shelf heading followed by the v1 track table.
private struct PageTrackSectionView: View {
	let module: PageModule
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	private var tracks: [Track] {
		pageModuleItems(module).compactMap(\.track)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ShelfHeader(
				title: module.title ?? "",
				subtitle: pageSubtitle(module),
				onViewAll: pageViewAllAction(module, viewState),
				showsScrollButtons: false
			)
			if !tracks.isEmpty {
				PageTrackTable(tracks: tracks, session: session, player: player)
			}
		}
	}
}
