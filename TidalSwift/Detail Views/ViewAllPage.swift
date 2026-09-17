//
//  ViewAllPage.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// Identifies the module a shelf's "View all" points at.
///
/// `path` is the module's `showMore.apiPath` (a single-module-page), `title` the
/// shelf title and `moduleType` the type used to dispatch the fetched items to
/// the existing cards.
struct ViewAllTarget: Codable, Equatable {
	let path: String
	let title: String
	let moduleType: PageModuleType
}

/// The route behind a shelf's "View all".
///
/// Fetches the module's single-module-page on appear and renders its items in a
/// 3-column wrapping grid of the existing `*GridItem` cards. The page returns
/// the first batch; further batches are fetched from the module's
/// `pagedList.dataApiPath` as the user scrolls to the bottom.
struct ViewAllPage: View {
	let target: ViewAllTarget
	let session: Session
	let player: Player

	@State private var items: [ShelfItem] = []
	@State private var moduleType: PageModuleType?
	@State private var loadingState: LoadingState = .loading
	@State private var dataApiPath: String?
	@State private var totalNumberOfItems: Int?
	@State private var batchSize: Int = 50
	@State private var isLoadingMore = false
	@State private var loadMoreFailed = false

	private var resolvedModuleType: PageModuleType {
		moduleType ?? target.moduleType
	}

	private var hasMore: Bool {
		guard let totalNumberOfItems else { return false }
		return items.count < totalNumberOfItems
	}

	var body: some View {
		ZStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					Text(target.title)
						.font(.largeTitle)
						.padding(.horizontal)
					content
				}
				.padding(.top, 40)
				.padding(.bottom, 16)
			}
			BackButton()
		}
		.task {
			await loadInitialPage()
		}
	}

	@ViewBuilder
	private var content: some View {
		if items.isEmpty {
			switch loadingState {
			case .loading:
				FullscreenLoadingSpinner(.loading)
			case .error:
				errorState
			case .successful:
				emptyState
			}
		} else if resolvedModuleType == .trackList {
			trackTable
		} else {
			grid
		}
	}

	private var grid: some View {
		VStack(alignment: .leading, spacing: 16) {
			LazyVGrid(
				columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
				spacing: 24
			) {
				ForEach(items) { item in
					moduleCard(
						for: item.item,
						moduleType: resolvedModuleType,
						showReleaseDate: true,
						session: session,
						player: player
					)
					.onAppear {
						// The last card appearing means the user reached the
						// bottom: fetch the next batch.
						guard item.id == items.last?.id else { return }
						Task { await loadNextBatch() }
					}
				}
			}
			footer
		}
		.padding(.horizontal)
	}

	/// Dense table for `TRACK_LIST` modules: one row per track with cover,
	/// title, artist, album, duration, BPM and Camelot key. BPM/KEY are only
	/// present when the track was fetched individually, so both fall back to
	/// "-". Batched loading is unchanged: the last row's `.onAppear` fetches the
	/// next batch.
	private var trackTable: some View {
		VStack(alignment: .leading, spacing: 0) {
			trackTableHeader
			Divider()
			LazyVStack(spacing: 0) {
				ForEach(items) { item in
					if let track = item.item.track {
						ViewAllTrackRow(track: track, session: session, player: player)
							.onAppear {
								guard item.id == items.last?.id else { return }
								Task { await loadNextBatch() }
							}
						Divider()
							.padding(.leading, 56)
					}
				}
			}
			footer
		}
		.padding(.horizontal)
	}

	private var trackTableHeader: some View {
		HStack(spacing: 8) {
			Color.clear
				.frame(width: 40, height: 1)
			Text("TITLE")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("ARTIST")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("ALBUM")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("TIME")
				.frame(width: 52, alignment: .trailing)
			Text("BPM")
				.frame(width: 44, alignment: .trailing)
			Text("KEY")
				.frame(width: 44, alignment: .center)
			Color.clear
				.frame(width: 84, height: 1)
		}
		.font(.caption)
		.fontWeight(.semibold)
		.foregroundColor(.secondary)
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
	}

	@ViewBuilder
	private var footer: some View {
		if hasMore {
			HStack {
				Spacer()
				if loadMoreFailed {
					Button("Try Again") {
						Task { await loadNextBatch() }
					}
				} else {
					LoadingSpinner(.loading)
				}
				Spacer()
			}
			.frame(height: 40)
		}
	}

	private var errorState: some View {
		ContentUnavailableView {
			Label("Couldn't Load Page", systemImage: "wifi.exclamationmark")
		} description: {
			Text("Your connection appears to be offline.")
		} actions: {
			Button("Try Again") {
				Task { await loadInitialPage() }
			}
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}

	private var emptyState: some View {
		ContentUnavailableView {
			Label("Nothing to Show", systemImage: "music.note.list")
		} description: {
			Text("This list didn't return any content.")
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}

	// MARK: - Loading

	private func loadInitialPage() async {
		guard items.isEmpty else { return }
		loadingState = .loading
		guard let page = await session.page(path: target.path) else {
			loadingState = .error
			return
		}
		guard let module = page.modules.first(where: { $0.pagedList != nil }) ?? page.modules.first else {
			loadingState = .successful
			return
		}
		moduleType = module.knownType
		append(module.pagedList?.items ?? module.items ?? [])
		dataApiPath = module.pagedList?.dataApiPath
		totalNumberOfItems = module.pagedList?.totalNumberOfItems
		if let limit = module.pagedList?.limit, limit > 0 {
			batchSize = limit
		}
		loadingState = .successful
	}

	private func loadNextBatch() async {
		guard !isLoadingMore, hasMore, let dataApiPath else { return }
		isLoadingMore = true
		loadMoreFailed = false
		defer { isLoadingMore = false }
		guard let batch = await session.pagedList(path: dataApiPath, offset: items.count, limit: batchSize) else {
			loadMoreFailed = true
			return
		}
		let previousCount = items.count
		append(batch.items)
		if let total = batch.totalNumberOfItems {
			totalNumberOfItems = total
		}
		if items.count == previousCount {
			// Nothing new: stop paging rather than retrying the same offset.
			totalNumberOfItems = items.count
		}
	}

	/// Appends items that aren't already in the list, keyed by `ShelfItem.id`.
	private func append(_ pageItems: [PageItem]) {
		var known = Set(items.map(\.id))
		for pageItem in pageItems {
			guard let item = ShelfItem(pageItem: pageItem), !known.contains(item.id) else { continue }
			known.insert(item.id)
			items.append(item)
		}
	}
}

/// A single dense row of the View-all track table.
///
/// Mirrors `TrackRow`'s affordances (cover, explicit badge, favorite toggle,
/// context menu) but lays the track out as fixed columns and adds BPM and the
/// Camelot key pill. BPM/KEY are only present when the track was fetched
/// individually, so both fall back to "-".
private struct ViewAllTrackRow: View {
	let track: Track
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var playbackInfo: PlaybackInfo
	@State private var isFavorite: Bool?

	private var isPlaying: Bool {
		guard !queueInfo.queue.isEmpty, queueInfo.queue.indices.contains(queueInfo.currentIndex) else { return false }
		return queueInfo.queue[queueInfo.currentIndex].track == track
	}

	var body: some View {
		HStack(spacing: 8) {
			cover
			titleColumn
			Text(track.artists.formArtistString())
				.frame(maxWidth: .infinity, alignment: .leading)
				.help(track.artists.formArtistString())
			Text(track.album.title)
				.frame(maxWidth: .infinity, alignment: .leading)
				.help(track.album.title)
			Text(secondsToHoursMinutesSecondsString(seconds: track.duration))
				.frame(width: 52, alignment: .trailing)
				.monospacedDigit()
			Text(track.bpm.map(String.init) ?? "-")
				.frame(width: 44, alignment: .trailing)
				.monospacedDigit()
			keyPill
				.frame(width: 44)
			actions
				.frame(width: 84)
		}
		.lineLimit(1)
		.padding(.horizontal, 8)
		.padding(.vertical, 3)
		.background(
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(isPlaying ? Color.controlAccentColor.opacity(0.25) : .clear)
		)
		.contentShape(Rectangle())
		.foregroundColor(track.isUnavailable || playbackInfo.failedTrackIds.contains(track.id) ? .secondary : .primary)
		.onTapGesture(count: 2) {
			guard !track.isUnavailable else { return }
			player.add(track: track, .now)
		}
		.contextMenu {
			TrackContextMenu(track: track, session: session, player: player)
		}
		.onReceive(NotificationCenter.default.publisher(for: .favoriteTrackChanged)) { note in
			guard let changedTrackId = note.userInfo?["trackId"] as? Int, changedTrackId == track.id else { return }
			isFavorite = note.userInfo?["isFavorite"] as? Bool
		}
		.task(id: track.id) {
			isFavorite = await track.isInFavorites(session: session)
		}
	}

	@ViewBuilder
	private var cover: some View {
		ZStack {
			if let coverUrl = track.getCoverUrl(session: session, resolution: 80) {
				AsyncImage(url: coverUrl) { image in
					image.resizable().scaledToFit()
				} placeholder: {
					Rectangle()
				}
			} else {
				Rectangle()
					.foregroundColor(.black)
			}
			if isPlaying {
				Rectangle()
					.fill(Color.black.opacity(0.45))
				Image(systemName: "play.fill")
					.foregroundColor(.white)
			}
		}
		.frame(width: 40, height: 40)
		.cornerRadius(CORNERRADIUS)
		.accessibilityHidden(true)
	}

	private var titleColumn: some View {
		HStack(spacing: 4) {
			Text(track.title)
			if let version = track.version {
				Text(version)
					.foregroundColor(.secondary)
					.layoutPriority(-1)
			}
			track.attributeHStack
				.layoutPriority(1)
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.help(trackToolTipString)
	}

	@ViewBuilder
	private var keyPill: some View {
		if track.camelotKey == "-" {
			Text("-")
				.foregroundColor(.secondary)
		} else {
			Text(track.camelotKey)
				.font(.caption2)
				.fontWeight(.semibold)
				.foregroundColor(.white)
				.padding(.horizontal, 6)
				.padding(.vertical, 2)
				.background(Capsule().fill(keyColor))
		}
	}

	private var keyColor: Color {
		switch track.camelotKey.last {
		case "A":
			return .blue
		case "B":
			return .red
		default:
			return .secondary
		}
	}

	private var actions: some View {
		HStack(spacing: 12) {
			Menu {
				TrackContextMenu(track: track, session: session, player: player)
			} label: {
				Image(systemName: "ellipsis")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.help("More")

			Button {
				player.add(track: track, .last)
			} label: {
				Image(systemName: "plus")
			}
			.buttonStyle(.plain)
			.help("Add to Queue")

			Button {
				toggleFavorite()
			} label: {
				Image(systemName: (isFavorite ?? false) ? "heart.fill" : "heart")
			}
			.buttonStyle(.plain)
			.help((isFavorite ?? false) ? "Remove from Favorites" : "Add to Favorites")
		}
		.secondaryIconColor()
	}

	private func toggleFavorite() {
		Task {
			if isFavorite ?? false {
				if await session.favorites?.removeTrack(trackId: track.id) == true {
					session.helpers.offline.asyncSyncFavoriteTracks()
					isFavorite = false
					NotificationCenter.default.post(name: .favoriteTrackChanged, object: nil, userInfo: ["trackId": track.id, "isFavorite": false])
				}
			} else {
				if await session.favorites?.addTrack(trackId: track.id) == true {
					session.helpers.offline.asyncSyncFavoriteTracks()
					isFavorite = true
					NotificationCenter.default.post(name: .favoriteTrackChanged, object: nil, userInfo: ["trackId": track.id, "isFavorite": true])
				}
			}
		}
	}

	private var trackToolTipString: String {
		var s = track.title
		if let version = track.version {
			s += " (\(version))"
		}
		s += " – \(track.artists.formArtistString())"
		return s
	}
}
