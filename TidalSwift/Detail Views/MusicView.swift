//
//  MusicView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// The three feeds of the Music tab.
enum MusicTab: String, CaseIterable, Identifiable {
	case forYou
	case staffPicks
	case uploads

	var id: Self { self }

	var title: String {
		switch self {
		case .forYou:
			return "For you"
		case .staffPicks:
			return "Staff Picks"
		case .uploads:
			return "Uploads"
		}
	}

	/// The page path backing the tab, or `nil` when the feed has no dedicated
	/// page and must be resolved from the home feed (see `RefreshMusicHome`).
	var path: String? {
		switch self {
		case .forYou:
			return "pages/for_you"
		case .staffPicks:
			return "pages/staff_picks"
		case .uploads:
			return nil
		}
	}
}

extension ViewCache {
	func homePage(for tab: MusicTab) -> Page? {
		switch tab {
		case .forYou:
			return homePageForYou
		case .staffPicks:
			return homePageStaffPicks
		case .uploads:
			return homePageUploads
		}
	}

	mutating func setHomePage(_ page: Page, for tab: MusicTab) {
		switch tab {
		case .forYou:
			homePageForYou = page
		case .staffPicks:
			homePageStaffPicks = page
		case .uploads:
			homePageUploads = page
		}
	}
}

/// The Music tab home: a segmented control switching between three feeds
/// (For you, Staff Picks, Uploads), each rendered as a vertical stack of
/// horizontal shelves.
///
/// Each page module becomes one `Shelf`; cards come from the shared
/// `moduleCard(for:moduleType:session:player:)` dispatch, so the existing grid
/// items are reused. Modules with no renderable items are skipped.
struct MusicHomeView: View {
	let session: Session
	let player: Player

	/// Invoked when a shelf's "View all" is clicked. When `nil` (the default),
	/// the View-all route is pushed onto the navigation stack.
	var onViewAll: ((ViewAllTarget) -> Void)?

	@EnvironmentObject var viewState: ViewState
	@State private var selectedTab: MusicTab = .forYou

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				Picker(selection: $selectedTab, label: Spacer(minLength: 0)) {
					ForEach(MusicTab.allCases) { tab in
						Text(tab.title).tag(tab)
					}
				}
				.pickerStyle(SegmentedPickerStyle())
				.padding(.horizontal)

				pinnedShelves

				content
			}
			.padding(.vertical)
		}
		.onChange(of: selectedTab) { _, tab in
			guard viewState.cache.homePage(for: tab) == nil else { return }
			viewState.music(tab: tab)
		}
	}

	@ViewBuilder
	private var content: some View {
		if let page = viewState.cache.homePage(for: selectedTab) {
			shelves(for: page)
		} else if viewState.stack.last?.loadingState == .error {
			errorState
		} else {
			FullscreenLoadingSpinner()
		}
	}

	/// Shelves backed by the app's own caches rather than the server page.
	///
	/// New Releases and My Mixes are populated by their own refreshers, so they
	/// are rendered above the server-supplied shelves whenever their cache is
	/// non-empty. "View all" pushes the corresponding base view.
	@ViewBuilder
	private var pinnedShelves: some View {
		if let albums = viewState.cache.newReleases, !albums.isEmpty {
			Shelf(
				title: "New Releases",
				onViewAll: { viewState.push(view: TidalSwiftView(viewType: .newReleases)) },
				items: albums,
				content: { album in
					AlbumGridItem(album: album, showArtists: true, showReleaseDate: true, session: session, player: player)
				}
			)
		}
		if let mixes = viewState.cache.mixes, !mixes.isEmpty {
			Shelf(
				title: "My Mixes",
				onViewAll: { viewState.push(view: TidalSwiftView(viewType: .myMixes)) },
				items: mixes,
				content: { mix in
					MixGridItem(mix: mix, session: session, player: player)
				}
			)
		}
	}

	@ViewBuilder
	private func shelves(for page: Page) -> some View {
		let models = shelfModels(from: page)
		if models.isEmpty {
			ContentUnavailableView {
				Label("Nothing to Show", systemImage: "music.note.list")
			} description: {
				Text("The home feed didn't return any content.")
			}
			.frame(maxWidth: .infinity, minHeight: 300)
		} else {
			LazyVStack(alignment: .leading, spacing: 24) {
				ForEach(models) { model in
					shelf(for: model)
				}
			}
		}
	}

	@ViewBuilder
	private func shelf(for model: ShelfModel) -> some View {
		if model.items.isEmpty {
			emptyShelf(for: model)
		} else {
			Shelf(
				title: model.title,
				onViewAll: model.viewAllPath.map { path in
					{
						handleViewAll(ViewAllTarget(path: path, title: model.title, moduleType: model.moduleType))
					}
				},
				items: model.items
			) { shelfItem in
				moduleCard(for: shelfItem.item, moduleType: model.moduleType, session: session, player: player)
			}
		}
	}

	/// A renderable module that returned no items still shows its header plus a
	/// short note, so the shelf reads as intentionally empty rather than as a
	/// blank gap in the feed.
	private func emptyShelf(for model: ShelfModel) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			ShelfHeader(
				title: model.title,
				onViewAll: model.viewAllPath.map { path in
					{
						handleViewAll(ViewAllTarget(path: path, title: model.title, moduleType: model.moduleType))
					}
				},
				canScrollBackward: false,
				canScrollForward: false
			)
			Text("No items")
				.font(.subheadline)
				.foregroundColor(.secondary)
				.padding(.horizontal)
		}
	}

	/// Pushes the View-all route for a shelf, unless the caller supplied its own
	/// `onViewAll` handler.
	private func handleViewAll(_ target: ViewAllTarget) {
		if let onViewAll {
			onViewAll(target)
		} else {
			viewState.push(view: TidalSwiftView(viewType: .viewAll, viewAllTarget: target))
		}
	}

	private var errorState: some View {
		ContentUnavailableView {
			Label("Couldn't Load Music", systemImage: "wifi.exclamationmark")
		} description: {
			Text("Check your internet connection, then try again.")
		} actions: {
			Button("Try Again") {
				viewState.music(tab: selectedTab)
			}
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}

	// MARK: - Page → shelves

	private func shelfModels(from page: Page) -> [ShelfModel] {
		page.modules.enumerated().compactMap { index, module in
			// Unknown module types (`knownType == nil`) and known-but-unrenderable
			// types (headers, links, text blocks, …) are skipped entirely, so an
			// unrecognized server type can never crash or render a stray shelf.
			guard let type = module.knownType, renderableModuleTypes.contains(type) else { return nil }
			let rawItems = module.pagedList?.items ?? module.items ?? []
			let items = rawItems.compactMap(ShelfItem.init(pageItem:))
			let title = module.title ?? ""
			// Renderable modules with no items still get a shelf so the empty
			// state is visible; a title-less empty module has nothing to show.
			guard !items.isEmpty || !title.isEmpty else { return nil }
			return ShelfModel(
				id: "\(module.id ?? type.rawValue)-\(index)",
				title: title,
				moduleType: type,
				items: items,
				viewAllPath: module.showMore?.apiPath ?? module.viewAll
			)
		}
	}
}

/// A page module prepared for rendering: a stable id, the server title, the
/// module type used for card dispatch, its renderable items and the optional
/// "View all" path.
private struct ShelfModel: Identifiable {
	let id: String
	let title: String
	let moduleType: PageModuleType
	let items: [ShelfItem]
	let viewAllPath: String?
}

/// A `PageItem` paired with a stable id, since `PageItem` itself is not
/// `Identifiable`. Items without a known payload are dropped. Shared with
/// `ViewAllPage`, which pages the same items.
struct ShelfItem: Identifiable {
	let id: String
	let item: PageItem

	init?(pageItem: PageItem) {
		guard let id = Self.identifier(for: pageItem) else { return nil }
		self.id = id
		self.item = pageItem
	}

	private static func identifier(for item: PageItem) -> String? {
		if let album = item.album { return "album-\(album.id)" }
		if let artist = item.artist { return "artist-\(artist.id)" }
		if let track = item.track { return "track-\(track.id)" }
		if let video = item.video { return "video-\(video.id)" }
		if let playlist = item.playlist { return "playlist-\(playlist.uuid)" }
		if let mix = item.mix { return "mix-\(mix.id)" }
		return nil
	}
}

/// Module types `moduleCard(for:moduleType:session:player:)` can render. Other
/// known types (headers, links, text blocks, …) are skipped rather than
/// rendered as empty shelves.
private let renderableModuleTypes: Set<PageModuleType> = [
	.albumList, .artistList, .playlistList, .trackList, .mixList, .videoList, .mixedTypesList
]
