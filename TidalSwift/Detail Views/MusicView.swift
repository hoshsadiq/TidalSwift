//
//  MusicView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib
import os

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

	/// The v2 home-feed slug backing the tab.
	var slug: String {
		switch self {
		case .forYou:
			return "static"
		case .staffPicks:
			return "editorial"
		case .uploads:
			return "uploads"
		}
	}
}

/// The Music tab home: an underlined text tab strip switching between three
/// v2 home feeds (For you, Staff Picks, Uploads), each rendered as a vertical
/// stack of horizontal shelves.
///
/// Each feed module becomes one `Shelf`; cards come from the shared
/// `homeFeedCard(for:artworkSize:session:player:)` dispatch, so the existing
/// grid items are reused. Shelves are responsive at four cards per row.
///
/// TODO: Unify this renderer with the v1 pages renderer (`PageView`) into one
/// API-driven module dispatch, so presentation fields (`layout`, `listFormat`,
/// `scroll`) drive layout for both feeds. Deferred on purpose — see
/// `.omo/plans/tidal-ui-explore.md`.
struct MusicHomeView: View {
	let session: Session
	let player: Player

	/// Invoked when a shelf's "View all" is clicked. When `nil` (the default),
	/// the View-all route is pushed onto the navigation stack.
	var onViewAll: ((ViewAllTarget) -> Void)?

	@EnvironmentObject var viewState: ViewState
	@State private var selectedTab: MusicTab = .uploads

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				tabStrip
				content
			}
			.padding(.vertical)
		}
		.onChange(of: selectedTab) { _, tab in
			guard viewState.cache.homeFeed(for: tab) == nil else { return }
			viewState.music(tab: tab)
		}
		.onAppear {
			Logger(subsystem: "de.melgu.TidalSwift", category: "magazine")
				.error("MUSIC VIEW APPEAR selectedTab=\(selectedTab.rawValue, privacy: .public) cached=\(viewState.cache.homeFeed(for: selectedTab) != nil, privacy: .public)")
		}
	}

	/// TIDAL's underlined text tab strip: the three feed titles left-aligned,
	/// the active one in the primary colour with a 2pt accent underline.
	private var tabStrip: some View {
		HStack(spacing: 24) {
			ForEach(MusicTab.allCases) { tab in
				tabButton(for: tab)
			}
		}
		.padding(.horizontal)
	}

	private func tabButton(for tab: MusicTab) -> some View {
		let isSelected = selectedTab == tab
		return Button {
			selectedTab = tab
		} label: {
			VStack(spacing: 4) {
				Text(tab.title)
					.font(.headline)
					.foregroundColor(isSelected ? .primary : .secondary)
				Rectangle()
					.fill(isSelected ? Color.controlAccentColor : Color.clear)
					.frame(height: 2)
			}
			.fixedSize()
		}
		.buttonStyle(.plain)
	}

	@ViewBuilder
	private var content: some View {
		if let feed = viewState.cache.homeFeed(for: selectedTab) {
			shelves(for: feed)
		} else if viewState.stack.last?.loadingState == .error {
			errorState
		} else {
			FullscreenLoadingSpinner()
		}
	}

	@ViewBuilder
	private func shelves(for feed: HomeFeedV2) -> some View {
		let models = shelfModels(from: feed)
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
	private func shelf(for model: HomeFeedShelfModel) -> some View {
		if model.compactGrid {
			CompactTrackList(
				title: model.title,
				subtitle: model.subtitle,
				onViewAll: model.viewAllPath.map { path in
					{
						handleViewAll(ViewAllTarget(path: path, title: model.title))
					}
				},
				items: model.items,
				session: session,
				player: player
			)
		} else {
			Shelf(
				title: model.title,
				subtitle: model.subtitle,
				onViewAll: model.viewAllPath.map { path in
					{
						handleViewAll(ViewAllTarget(path: path, title: model.title))
					}
				},
				items: model.items,
				cardsPerPage: 4
			) { shelfItem, cardWidth in
				// The grid items add 5pt padding on each side, so the artwork is
				// the resolved card footprint minus that 10pt.
				homeFeedCard(
					for: shelfItem.item,
					artworkSize: cardWidth - 10,
					session: session,
					player: player
				)
			}
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

	// MARK: - Feed → shelves

	private func shelfModels(from feed: HomeFeedV2) -> [HomeFeedShelfModel] {
		feed.items.enumerated().map { index, module in
			let items = module.items.compactMap { HomeFeedShelfItem($0) }
			return HomeFeedShelfModel(
				id: "\(module.moduleId ?? module.type)-\(index)",
				title: module.title ?? "",
				subtitle: module.subtitle,
				items: items,
				viewAllPath: module.viewAll,
				compactGrid: isCompactGrid(module: module)
			)
		}
	}

	/// Whether a module renders as TIDAL's compact 3-column track list instead of
	/// a horizontal shelf. The v2 feed marks these `COMPACT_GRID_CARD`; a legacy
	/// `HORIZONTAL_LIST` of tracks keeps TIDAL's carousel layout.
	private func isCompactGrid(module: HomeFeedModule) -> Bool {
		module.type == "COMPACT_GRID_CARD"
	}
}

/// A feed module prepared for rendering: a stable id, the server title and
/// subtitle, its renderable items and the optional "View all" path.
private struct HomeFeedShelfModel: Identifiable {
	let id: String
	let title: String
	let subtitle: String?
	let items: [HomeFeedShelfItem]
	let viewAllPath: String?
	let compactGrid: Bool
}
