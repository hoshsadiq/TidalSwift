//
//  ViewAllPage.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 16.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// Identifies the module a shelf's "View all" points at.
///
/// `path` is the module's v2 `viewAll` path (e.g.
/// `home/pages/DAILY_MIXES/view-all`, relative to the v2 base) and `title` the
/// shelf title.
struct ViewAllTarget: Codable, Equatable {
	let path: String
	let title: String
}

/// Identifies a v1 page pushed as a `.page` route.
///
/// `path` is the page's relative path (e.g. `pages/explore`,
/// `pages/genre_blues`, `pages/single-module-page/…`, relative to the v1 base)
/// and `title` the title shown while the page loads and in navigation.
struct PageTarget: Codable, Equatable {
	let path: String
	let title: String
}

/// The route behind a shelf's "View all".
///
/// Fetches the v2 view-all page on appear and renders its items either as the
/// dense track table (when the items are tracks) or as a responsive wrapping
/// grid of the shared home-feed cards. The v2 response carries no total count, so
/// further batches are fetched with `offset = items.count` as the user scrolls
/// to the bottom, stopping once a batch adds nothing new or comes back short.
struct ViewAllPage: View {
	let target: ViewAllTarget
	let session: Session
	let player: Player

	@State private var items: [HomeFeedShelfItem] = []
	@State private var loadingState: LoadingState = .loading
	@State private var batchSize: Int = 50
	@State private var hasMore = false
	@State private var isLoadingMore = false
	@State private var loadMoreFailed = false
	/// Items seen so far whose payload we can't represent, surfaced as a notice.
	@State private var unsupportedCount = 0
	/// Measured grid content width, driving the responsive column count.
	@State private var contentWidth: CGFloat = 0

	/// Decides the layout from the fetched items: the track table only when
	/// every item is a track, the grid otherwise, so no item is ever dropped by
	/// the table's track-only rows. Before anything is loaded the spinner is
	/// shown, so the grid is the no-data default.
	private var usesTrackTable: Bool {
		guard !items.isEmpty else { return false }
		return items.allSatisfy { $0.item.track != nil }
	}

	/// Preferred card width used to derive the column count from the measured
	/// content width, matching the Music tab's shelf cards.
	private let preferredCardWidth: CGFloat = 275
	/// Horizontal gap between grid columns.
	private let gridSpacing: CGFloat = 16

	/// Columns that fit the measured content width at `preferredCardWidth`,
	/// never fewer than two.
	private var gridColumns: Int {
		guard contentWidth > 0 else { return 3 }
		return max(2, Int((contentWidth + gridSpacing) / (preferredCardWidth + gridSpacing)))
	}

	/// Card footprint for the current column count, so the artwork and the text
	/// under it fill the cell. The grid items add 5pt padding on each side, so
	/// the artwork is this minus 10pt.
	private var gridCardWidth: CGFloat {
		guard contentWidth > 0 else { return preferredCardWidth }
		let columns = gridColumns
		return (contentWidth - CGFloat(columns - 1) * gridSpacing) / CGFloat(columns)
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				Text(target.title)
					.font(.largeTitle)
					.padding(.horizontal)
				content
			}
			.padding(.bottom, 16)
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
		} else {
			VStack(alignment: .leading, spacing: 16) {
				if usesTrackTable {
					trackTable
				} else {
					grid
				}
				unsupportedNotice
			}
		}
	}

	/// One discreet line when a batch carried items we can't represent, so the
	/// page is honest about being shorter than the section actually is.
	@ViewBuilder
	private var unsupportedNotice: some View {
		if unsupportedCount > 0 {
			Text("Some items in this section aren't supported yet.")
				.font(.caption)
				.foregroundColor(.secondary)
				.padding(.horizontal)
		}
	}

	private var grid: some View {
		VStack(alignment: .leading, spacing: 16) {
			LazyVGrid(
				columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: gridColumns),
				spacing: 24
			) {
				ForEach(items) { item in
					homeFeedCard(
						for: item.item,
						showReleaseDate: true,
						artworkSize: gridCardWidth - 10,
						mixSubtitle: item.item.mix?.description,
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

	/// Dense table for track lists: one row per track with cover, title, artist,
	/// album, duration, BPM and Camelot key. BPM/KEY are only present when the
	/// track was fetched individually, so both fall back to "-". Batched loading
	/// is unchanged: a sentinel at the end of the list fetches the next batch.
	private var trackTable: some View {
		VStack(alignment: .leading, spacing: 0) {
			trackTableHeader
			Divider()
			LazyVStack(spacing: 0) {
				ForEach(items) { item in
					if let track = item.item.track {
						ViewAllTrackRow(track: track.asTrack, session: session, player: player)
						Divider()
							.padding(.leading, 56)
					}
				}
				// Sentinel at the end of the list, so paging fires when the
				// bottom is reached regardless of how the last row rendered.
				Color.clear
					.frame(height: 1)
					.onAppear {
						Task { await loadNextBatch() }
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
		guard let page = await session.homeFeedViewAll(path: target.path, limit: batchSize) else {
			loadingState = .error
			return
		}
		append(page.items)
		hasMore = !items.isEmpty && page.items.count >= batchSize
		loadingState = .successful
	}

	private func loadNextBatch() async {
		guard !isLoadingMore, hasMore else { return }
		isLoadingMore = true
		loadMoreFailed = false
		defer { isLoadingMore = false }
		let requestedLimit = batchSize
		guard let batch = await session.homeFeedViewAll(
			path: target.path,
			limit: requestedLimit,
			offset: items.count
		) else {
			loadMoreFailed = true
			return
		}
		let previousCount = items.count
		append(batch.items)
		// No total count in v2: stop once a batch adds nothing new or comes back
		// short of the requested limit.
		if items.count == previousCount || batch.items.count < requestedLimit {
			hasMore = false
		}
	}

	/// Appends items that aren't already in the list, keyed by `HomeFeedShelfItem.id`.
	private func append(_ feedItems: [HomeFeedItem]) {
		var known = Set(items.map(\.id))
		for feedItem in feedItems {
			guard let item = HomeFeedShelfItem(feedItem) else {
				unsupportedCount += 1
				continue
			}
			guard !known.contains(item.id) else { continue }
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
