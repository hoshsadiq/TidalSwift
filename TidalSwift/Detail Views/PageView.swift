//
//  PageView.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib
import os

/// Renders a v1 page pushed as a `.page` route.
///
/// Shows the page title and each module in the server's order, dispatching on
/// the module's `type`: text blocks, link grids/pill rows, shelves (playlists,
/// albums, artists, mixes, videos), the v1 track table and the featured hero.
/// Unknown module types are skipped and logged. Pages are cached by path in
/// `ViewCache.pages`, so back/forward renders instantly.
///
/// A single-module page whose module pages its list (TIDAL's "View all"
/// destination: one module advertising `supportsPaging` and carrying a
/// `pagedList.dataApiPath`) renders that module as the page body instead of a
/// shelf and appends further batches through an explicit "Load More" footer,
/// stopping once the module's server-reported total is reached or a batch adds
/// nothing new. There is no scroll-triggered loading.
struct PageView: View {
	let target: PageTarget
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	@State private var page: Page?
	@State private var loadingState: LoadingState = .loading

	/// Items of a pageable single-module page, seeded with the module's first
	/// batch and grown by "Load More".
	@State private var pagedItems: [PageItem] = []
	@State private var hasMore = false
	@State private var isLoadingMore = false
	@State private var loadMoreFailed = false

	private static let logger = Logger(subsystem: "de.melgu.TidalSwift", category: "page")

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				Text(page?.title ?? target.title)
					.font(.largeTitle)
					.padding(.horizontal)
				content
			}
			.padding(.vertical)
		}
		.task { await load() }
	}

	@ViewBuilder
	private var content: some View {
		if let page {
			let modules = page.modules
			if modules.isEmpty {
				emptyState
			} else if let module = Self.pagingModule(in: page) {
				if pagedItems.isEmpty && !hasMore {
					emptyState
				} else {
					PagePagedModuleView(
						items: pagedItems,
						kind: Self.itemKind(for: module.knownType),
						hasMore: hasMore,
						isLoadingMore: isLoadingMore,
						loadMoreFailed: loadMoreFailed,
						onLoadMore: { Task { await loadMore() } },
						session: session,
						player: player
					)
				}
			} else {
				ForEach(modules.indices, id: \.self) { index in
					PageModuleContent(module: modules[index], session: session, player: player)
				}
			}
		} else {
			switch loadingState {
			case .loading:
				FullscreenLoadingSpinner(.loading)
			case .error:
				errorState
			case .successful:
				emptyState
			}
		}
	}

	private var errorState: some View {
		ContentUnavailableView {
			Label("Couldn't Load Page", systemImage: "wifi.exclamationmark")
		} description: {
			Text("Your connection appears to be offline.")
		} actions: {
			Button("Try Again") {
				Task { await load() }
			}
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}

	private var emptyState: some View {
		ContentUnavailableView {
			Label("Nothing to Show", systemImage: "music.note.list")
		} description: {
			Text("This page didn't return any content.")
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}

	/// Reads the page from the cache when present, otherwise fetches it and
	/// stores the result. A failed fetch shows the error state, whose retry
	/// calls this again.
	private func load() async {
		if let cached = viewState.cache.pages[target.path] {
			adopt(cached)
			return
		}
		loadingState = .loading
		guard let fetched = await session.page(path: target.path) else {
			loadingState = .error
			return
		}
		viewState.cache.pages[target.path] = fetched
		adopt(fetched)
	}

	/// Installs a fetched or cached page and seeds the paging state from its
	/// module, so "Load More" continues from the batch the page arrived with.
	private func adopt(_ page: Page) {
		self.page = page
		if let module = Self.pagingModule(in: page) {
			pagedItems = pageModuleItems(module)
			let total = module.pagedList?.totalNumberOfItems
			hasMore = total.map { pagedItems.count < $0 } ?? (pagedItems.count >= Self.batchSize(for: module))
		} else {
			pagedItems = []
			hasMore = false
		}
		isLoadingMore = false
		loadMoreFailed = false
		loadingState = .successful
		logUnknownModules(in: page)
	}

	// MARK: - Paging

	/// The single module of a "View all" page, when it pages its list: exactly
	/// one module that advertises `supportsPaging` and carries the
	/// `pagedList.dataApiPath` further batches are fetched from.
	private static func pagingModule(in page: Page) -> PageModule? {
		let modules = page.modules
		guard modules.count == 1, let module = modules.first else { return nil }
		guard module.supportsPaging == true, module.pagedList?.dataApiPath != nil else { return nil }
		return module
	}

	/// The item kind a pageable list module carries. Needed because an album
	/// payload also satisfies the tolerant `PageVideo` decoder, so the module's
	/// type — not the item — decides the card and the identity.
	private static func itemKind(for type: PageModuleType?) -> PageItemKind? {
		switch type {
		case .trackList:
			return .track
		case .albumList:
			return .album
		case .artistList:
			return .artist
		case .playlistList:
			return .playlist
		case .videoList:
			return .video
		case .mixList:
			return .mix
		default:
			return nil
		}
	}

	/// The module's server-supplied page size, capped at the `pages/data`
	/// maximum: a larger `limit` is rejected with HTTP 400 ("Too big page").
	/// Pageable modules report 50, so the cap is insurance.
	private static func batchSize(for module: PageModule) -> Int {
		guard let limit = module.pagedList?.limit, limit > 0 else { return maximumBatchSize }
		return min(limit, maximumBatchSize)
	}

	/// Largest batch `pages/data` accepts.
	private static let maximumBatchSize = 50

	/// Fetches the next batch with the current item count as the offset and
	/// appends it. Without a server total, paging stops once a batch comes back
	/// short or adds nothing new.
	private func loadMore() async {
		guard !isLoadingMore, hasMore,
			  let module = page.flatMap({ Self.pagingModule(in: $0) }),
			  let path = module.pagedList?.dataApiPath else { return }
		isLoadingMore = true
		loadMoreFailed = false
		defer { isLoadingMore = false }

		let requestedLimit = Self.batchSize(for: module)
		guard let batch = await session.pagedList(path: path, offset: pagedItems.count, limit: requestedLimit) else {
			loadMoreFailed = true
			return
		}

		let previousCount = pagedItems.count
		append(batch.items, kind: Self.itemKind(for: module.knownType))
		if let total = batch.totalNumberOfItems {
			hasMore = pagedItems.count < total
		} else {
			hasMore = pagedItems.count > previousCount && batch.items.count >= requestedLimit
		}
	}

	/// Appends items that aren't already in the list, keyed by their stable id,
	/// so a repeated batch can't duplicate rows.
	private func append(_ items: [PageItem], kind: PageItemKind?) {
		var known = Set(pagedItems.compactMap { PageShelfItem($0, kind: kind)?.id })
		for item in items {
			if let id = PageShelfItem(item, kind: kind)?.id {
				guard known.insert(id).inserted else { continue }
			}
			pagedItems.append(item)
		}
	}

	/// Logs each module type this renderer doesn't know, once per type, so an
	/// unsupported page is diagnosable without spamming the log.
	private func logUnknownModules(in page: Page) {
		var logged = Set<String>()
		for module in page.modules where module.knownType == nil {
			guard logged.insert(module.type).inserted else { continue }
			Self.logger.error("page unknown module type=\(module.type, privacy: .public) path=\(target.path, privacy: .public)")
		}
	}
}

/// The body of a pageable single-module page: the module's items rendered
/// full-page — the v1 track table for tracks, a wrapping grid of the shared v1
/// cards otherwise — followed by the explicit "Load More" footer. The module's
/// own heading is omitted because the page title already carries it.
private struct PagePagedModuleView: View {
	let items: [PageItem]
	let kind: PageItemKind?
	let hasMore: Bool
	let isLoadingMore: Bool
	let loadMoreFailed: Bool
	let onLoadMore: () -> Void
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@State private var collectionMixIds: Set<String> = []

	/// Measured grid content width, driving the responsive column count.
	@State private var contentWidth: CGFloat = 0

	/// Preferred card width used to derive the column count from the measured
	/// content width, matching the v2 View-all grid.
	private let preferredCardWidth: CGFloat = 275
	/// Horizontal gap between grid columns.
	private let gridSpacing: CGFloat = 16

	/// Columns that fit the measured content width at `preferredCardWidth`,
	/// never fewer than two.
	private var gridColumns: Int {
		guard contentWidth > 0 else { return 3 }
		return max(2, Int((contentWidth + gridSpacing) / (preferredCardWidth + gridSpacing)))
	}

	/// Card footprint for the current column count. The cards add 5pt padding on
	/// each side, so a square card's artwork is this minus 10pt; a wide video
	/// card multiplies its artwork by 2.1, so its artwork is derived instead.
	private var artworkSize: CGFloat {
		guard contentWidth > 0 else { return preferredCardWidth }
		let columns = gridColumns
		let cell = (contentWidth - CGFloat(columns - 1) * gridSpacing) / CGFloat(columns)
		guard kind == .video else { return max(1, cell - 10) }
		return max(1, (cell - 10) / 2.1)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			if kind == .track {
				let tracks = items.compactMap(\.track)
				if !tracks.isEmpty {
					PageTrackTable(tracks: tracks, session: session, player: player)
				}
			} else {
				grid
			}
			footer
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

	private var grid: some View {
		LazyVGrid(
			columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: gridColumns),
			spacing: 24
		) {
			ForEach(items.compactMap { PageShelfItem($0, kind: kind) }) { item in
				pageCard(
					for: item.item,
					kind: kind,
					artworkSize: artworkSize,
					collectionMixIds: collectionMixIds,
					onToggleMixHeart: { viewState.toggleMixInCollection($0) },
					session: session,
					player: player
				)
			}
		}
		.background(
			GeometryReader { geometry in
				Color.clear
					.onAppear { contentWidth = geometry.size.width }
					.onChange(of: geometry.size.width) { _, newWidth in
						contentWidth = newWidth
					}
			}
		)
		.padding(.horizontal)
	}

	private func refreshCollectionMixIds() {
		guard kind == .mix else { return }
		collectionMixIds = Set(viewState.cache.collectionMixes?.map(\.id) ?? [])
	}

	/// The explicit paging control: "Load More" at rest, a spinner while a batch
	/// is in flight and "Try Again" after a failed one. Loading is never
	/// triggered by scrolling.
	@ViewBuilder
	private var footer: some View {
		if hasMore {
			HStack {
				Spacer()
				if isLoadingMore {
					LoadingSpinner(.loading)
				} else if loadMoreFailed {
					Button("Try Again", action: onLoadMore)
				} else {
					Button("Load More", action: onLoadMore)
				}
				Spacer()
			}
			.frame(height: 40)
		}
	}
}
