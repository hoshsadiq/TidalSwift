//
//  CollectionScreens.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

let PICKERWIDTH: CGFloat = 580

struct ReverseButton: View {
	@Binding var reversed: Bool

	var body: some View {
		Button {
			reversed.toggle()
		} label: {
			if reversed {
				Text("∨")
//				Image(systemName: "arrow.down")
			} else {
				Text("∧")
//				Image(systemName: "arrow.up")
			}
		}
	}
}

// MARK: - Playlists

/// Sort options for Collection ▸ Playlists. `Playlist` carries both `created`
/// and `lastUpdated`, so all three are real client-side sorts.
private enum CollectionPlaylistSort: CaseIterable {
	case created
	case updated
	case alphabetical

	var label: String {
		switch self {
		case .created: return "Created date"
		case .updated: return "Updated date"
		case .alphabetical: return "Alphabetical"
		}
	}
}

struct CollectionPlaylists: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	@State private var filterText = ""
	@State private var sortOption: CollectionPlaylistSort = .created

	private var displayedPlaylists: [Playlist] {
		guard let playlists = viewState.stack.last?.playlists else { return [] }
		let filtered = filterText.isEmpty ? playlists : playlists.filter {
			$0.title.localizedCaseInsensitiveContains(filterText) ||
				($0.creator.name ?? "").localizedCaseInsensitiveContains(filterText)
		}
		switch sortOption {
		case .created:
			return filtered.sorted { $0.created > $1.created }
		case .updated:
			return filtered.sorted { $0.lastUpdated > $1.lastUpdated }
		case .alphabetical:
			return filtered.sorted { $0.title.lowercased() < $1.title.lowercased() }
		}
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text("Playlists")
						.font(.largeTitle)
						.lineLimit(1)
					Spacer()
					LoadingSpinner()
				}
				HStack(spacing: 12) {
					FilterField(placeholder: "Filter playlists", text: $filterText)
					SortMenu(options: CollectionPlaylistSort.allCases, label: { $0.label }, selection: $sortOption)
				}
				content
				Spacer(minLength: 0)
			}
			.padding()
		}
	}

	@ViewBuilder
	private var content: some View {
		if let playlists = viewState.stack.last?.playlists, !playlists.isEmpty {
			if displayedPlaylists.isEmpty {
				CollectionNoResultsState()
			} else {
				HStack {
					Text("\(playlists.count) \(playlists.count == 1 ? "Playlist" : "Playlists")")
					Spacer()
				}
				PlaylistGrid(playlists: displayedPlaylists, session: session, player: player, showCreator: true, showItemCount: true, showsMosaic: true)
			}
		} else if viewState.stack.last?.loadingState == .successful {
			CollectionEmptyState(
				systemImage: "list.bullet",
				message: "You haven't added any playlists yet. Tap the heart icon on any playlist to add it to your collection."
			)
		}
	}
}

// MARK: - Albums

/// Sort options for Collection ▸ Albums. `Album` carries `releaseDate` and
/// `title`; the API's `created` is dropped by the unwrapped model, so "Date
/// added" is the loader's own date-added-descending order.
private enum CollectionAlbumSort: CaseIterable {
	case dateAdded
	case releaseDate
	case alphabetical

	var label: String {
		switch self {
		case .dateAdded: return "Date added"
		case .releaseDate: return "Release date"
		case .alphabetical: return "Alphabetical"
		}
	}
}

struct CollectionAlbums: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	@State private var filterText = ""
	@State private var sortOption: CollectionAlbumSort = .dateAdded

	private var displayedAlbums: [Album] {
		guard let albums = viewState.stack.last?.albums else { return [] }
		let filtered = filterText.isEmpty ? albums : albums.filter {
			$0.title.localizedCaseInsensitiveContains(filterText) ||
				($0.artists?.formArtistString() ?? $0.artist?.name ?? "").localizedCaseInsensitiveContains(filterText)
		}
		switch sortOption {
		case .dateAdded:
			return filtered
		case .releaseDate:
			return filtered.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
		case .alphabetical:
			return filtered.sorted { $0.title.lowercased() < $1.title.lowercased() }
		}
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text("Albums")
						.font(.largeTitle)
						.lineLimit(1)
					Spacer()
					LoadingSpinner()
				}
				HStack(spacing: 12) {
					FilterField(placeholder: "Filter albums", text: $filterText)
					SortMenu(options: CollectionAlbumSort.allCases, label: { $0.label }, selection: $sortOption)
				}
				content
				Spacer(minLength: 0)
			}
			.padding()
		}
	}

	@ViewBuilder
	private var content: some View {
		if let albums = viewState.stack.last?.albums, !albums.isEmpty {
			if displayedAlbums.isEmpty {
				CollectionNoResultsState()
			} else {
				HStack {
					Text("\(albums.count) \(albums.count == 1 ? "Album" : "Albums")")
					Spacer()
				}
				AlbumGrid(albums: displayedAlbums, showArtists: true, showReleaseDate: true, showsReleaseYear: true, session: session, player: player)
			}
		} else if viewState.stack.last?.loadingState == .successful {
			CollectionEmptyState(
				systemImage: "opticaldisc",
				message: "You haven't added any albums yet. Tap the heart icon on any album to add it to your collection.",
				actionTitle: "View TIDAL's top albums",
				action: { viewState.push(page: PageTarget(path: "pages/top_albums", title: "Top Albums")) }
			)
		}
	}
}

// MARK: - Tracks

/// Sort options for Collection ▸ Tracks. The loader fetches date-added
/// descending, so "Date added" is that order and only Alphabetical re-sorts.
private enum CollectionTrackSort: CaseIterable {
	case dateAdded
	case alphabetical

	var label: String {
		switch self {
		case .dateAdded: return "Date added"
		case .alphabetical: return "Alphabetical"
		}
	}
}

struct CollectionTracks: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	@State private var filterText = ""
	@State private var sortOption: CollectionTrackSort = .dateAdded

	/// The favourites with their dates, as stored by the loader.
	private var entries: [CollectionTrackEntry] {
		viewState.cache.collectionTracks ?? []
	}

	private var displayedEntries: [CollectionTrackEntry] {
		let filtered = filterText.isEmpty ? entries : entries.filter {
			$0.track.title.localizedCaseInsensitiveContains(filterText) ||
				$0.track.artists.formArtistString().localizedCaseInsensitiveContains(filterText) ||
				$0.track.album.title.localizedCaseInsensitiveContains(filterText)
		}
		switch sortOption {
		case .dateAdded:
			return filtered
		case .alphabetical:
			return filtered.sorted { $0.track.title.lowercased() < $1.track.title.lowercased() }
		}
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text("Tracks")
						.font(.largeTitle)
						.lineLimit(1)
					Spacer()
					LoadingSpinner()
				}
				if !displayedEntries.isEmpty {
					PlayShuffleHeader(onPlay: play, onShuffle: shuffle)
				}
				HStack(spacing: 12) {
					FilterField(placeholder: "Filter tracks", text: $filterText)
					SortMenu(options: CollectionTrackSort.allCases, label: { $0.label }, selection: $sortOption, triggerStyle: .label)
				}
				content
				Spacer(minLength: 0)
			}
			.padding()
		}
	}

	@ViewBuilder
	private var content: some View {
		if entries.isEmpty {
			if viewState.stack.last?.loadingState == .successful {
				CollectionEmptyState(
					systemImage: "music.note.list",
					message: "You haven't added any tracks yet. Tap the heart icon on any track to add it to your collection."
				)
			}
		} else if displayedEntries.isEmpty {
			CollectionNoResultsState()
		} else {
			HStack {
				Text("\(entries.count) \(entries.count == 1 ? "Track" : "Tracks")")
				Spacer()
			}
			table
		}
	}

	private var table: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			Divider()
			LazyVStack(spacing: 0) {
				ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { index, entry in
					CollectionTrackRow(track: entry.track, index: index + 1, dateAdded: entry.created, session: session, player: player)
					Divider()
						.padding(.leading, 56)
				}
			}
		}
	}

	private var header: some View {
		HStack(spacing: 8) {
			Text("#")
				.frame(width: 24, alignment: .trailing)
			Color.clear
				.frame(width: 40, height: 1)
			Text("TITLE")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("ARTIST")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("ALBUM")
				.frame(maxWidth: .infinity, alignment: .leading)
			Text("DATE ADDED")
				.frame(width: 90, alignment: .leading)
			Text("TIME")
				.frame(width: 52, alignment: .trailing)
			Text("BPM")
				.frame(width: 44, alignment: .trailing)
			Color.clear
				.frame(width: 76, height: 1)
		}
		.font(.caption)
		.fontWeight(.semibold)
		.foregroundColor(.secondary)
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
	}

	private func play() {
		let tracks = displayedEntries.map(\.track)
		guard !tracks.isEmpty else { return }
		player.playbackInfo.shuffle = false
		player.add(tracks: tracks, .now, source: QueueSource(type: .favorite, title: "Collection"))
	}

	private func shuffle() {
		let tracks = displayedEntries.map(\.track)
		guard !tracks.isEmpty else { return }
		player.playbackInfo.shuffle = true
		player.add(tracks: tracks, .now, source: QueueSource(type: .favorite, title: "Collection"))
	}
}

/// A single row of the Collection ▸ Tracks table.
///
/// Mirrors `TrackRow`'s affordances (cover, explicit badge, favourite toggle,
/// context menu) but lays the track out as fixed columns and adds the row
/// number, the date added and BPM.
private struct CollectionTrackRow: View {
	let track: Track
	let index: Int
	let dateAdded: Date?
	let session: Session
	let player: Player

	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var playbackInfo: PlaybackInfo
	@State private var isFavorite: Bool?

	private var isPlaying: Bool {
		guard !queueInfo.queue.isEmpty, queueInfo.queue.indices.contains(queueInfo.currentIndex) else { return false }
		return queueInfo.queue[queueInfo.currentIndex].track == track
	}

	var body: some View {
		HStack(spacing: 8) {
			Text("\(index)")
				.fontWeight(.thin)
				.foregroundColor(.secondary)
				.monospacedDigit()
				.frame(width: 24, alignment: .trailing)
			cover
			titleColumn
				.frame(maxWidth: .infinity, alignment: .leading)
			Text(track.artists.formArtistString())
				.frame(maxWidth: .infinity, alignment: .leading)
				.help(track.artists.formArtistString())
			Text(track.album.title)
				.frame(maxWidth: .infinity, alignment: .leading)
				.help(track.album.title)
			Text(dateAdded.map(relativeDateAddedString) ?? "-")
				.frame(width: 90, alignment: .leading)
			Text(secondsToHoursMinutesSecondsString(seconds: track.duration))
				.frame(width: 52, alignment: .trailing)
				.monospacedDigit()
			Text(track.bpm.map(String.init) ?? "-")
				.frame(width: 44, alignment: .trailing)
				.monospacedDigit()
			actions
				.frame(width: 76)
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
				ArtworkImage(url: coverUrl, size: 40, showsShadow: false)
			} else {
				Rectangle()
					.foregroundColor(.black)
					.frame(width: 40, height: 40)
					.cornerRadius(CORNERRADIUS)
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
		.help(trackToolTipString)
	}

	private var actions: some View {
		HStack(spacing: 12) {
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

// MARK: - Videos

/// Sort options for Collection ▸ Videos. `Video` carries `title`; the API's
/// `created` is dropped by the unwrapped model, so "Date added" is the loader's
/// own date-added-descending order.
private enum CollectionVideoSort: CaseIterable {
	case dateAdded
	case alphabetical

	var label: String {
		switch self {
		case .dateAdded: return "Date added"
		case .alphabetical: return "Alphabetical"
		}
	}
}

struct CollectionVideos: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	@State private var filterText = ""
	@State private var sortOption: CollectionVideoSort = .dateAdded

	private var displayedVideos: [Video] {
		guard let videos = viewState.stack.last?.videos else { return [] }
		let filtered = filterText.isEmpty ? videos : videos.filter {
			$0.title.localizedCaseInsensitiveContains(filterText) ||
				$0.artists.formArtistString().localizedCaseInsensitiveContains(filterText)
		}
		switch sortOption {
		case .dateAdded:
			return filtered
		case .alphabetical:
			return filtered.sorted { $0.title.lowercased() < $1.title.lowercased() }
		}
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text("Videos")
						.font(.largeTitle)
						.lineLimit(1)
					Spacer()
					LoadingSpinner()
				}
				HStack(spacing: 12) {
					FilterField(placeholder: "Filter videos", text: $filterText)
					SortMenu(options: CollectionVideoSort.allCases, label: { $0.label }, selection: $sortOption)
				}
				content
				Spacer(minLength: 0)
			}
			.padding()
		}
	}

	@ViewBuilder
	private var content: some View {
		if let videos = viewState.stack.last?.videos, !videos.isEmpty {
			if displayedVideos.isEmpty {
				CollectionNoResultsState()
			} else {
				HStack {
					Text("\(videos.count) \(videos.count == 1 ? "Video" : "Videos")")
					Spacer()
				}
				VideoGrid(videos: displayedVideos, showArtists: true, session: session, player: player, wide: true, showsHDBadge: true)
			}
		} else if viewState.stack.last?.loadingState == .successful {
			CollectionEmptyState(
				systemImage: "play.rectangle",
				message: "You haven't added any videos yet. Tap the heart icon on any video to add it to your collection."
			)
		}
	}
}

// MARK: - Profiles

/// Sort options for Collection ▸ Profiles. `Artist` carries `name`; the API's
/// `created` is dropped by the unwrapped model, so "Date added" is the loader's
/// own date-added-descending order.
private enum CollectionProfileSort: CaseIterable {
	case dateAdded
	case alphabetical

	var label: String {
		switch self {
		case .dateAdded: return "Date added"
		case .alphabetical: return "Alphabetical"
		}
	}
}

struct CollectionProfiles: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	@State private var filterText = ""
	@State private var sortOption: CollectionProfileSort = .dateAdded

	private var displayedArtists: [Artist] {
		guard let artists = viewState.stack.last?.artists else { return [] }
		let filtered = filterText.isEmpty ? artists : artists.filter {
			$0.name.localizedCaseInsensitiveContains(filterText)
		}
		switch sortOption {
		case .dateAdded:
			return filtered
		case .alphabetical:
			return filtered.sorted { $0.name.lowercased() < $1.name.lowercased() }
		}
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				HStack {
					Text("Profiles")
						.font(.largeTitle)
						.lineLimit(1)
					Spacer()
					LoadingSpinner()
				}
				HStack(spacing: 12) {
					FilterField(placeholder: "Filter profiles", text: $filterText)
					SortMenu(options: CollectionProfileSort.allCases, label: { $0.label }, selection: $sortOption)
				}
				content
				Spacer(minLength: 0)
			}
			.padding()
		}
	}

	@ViewBuilder
	private var content: some View {
		if let artists = viewState.stack.last?.artists, !artists.isEmpty {
			if displayedArtists.isEmpty {
				CollectionNoResultsState()
			} else {
				HStack {
					Text("\(artists.count) \(artists.count == 1 ? "Artist" : "Artists")")
					Spacer()
				}
				ArtistGrid(artists: displayedArtists, session: session, player: player, circular: true)
			}
		} else if viewState.stack.last?.loadingState == .successful {
			CollectionEmptyState(
				systemImage: "person.crop.circle",
				message: "You haven't added any profiles yet. Tap the heart icon on any artist to add it to your collection."
			)
		}
	}
}

// MARK: - Mixes & Radio

struct CollectionMixes: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	@State private var isLoadingMore = false
	@State private var loadMoreFailed = false

	private var mixes: [MixesItem] {
		viewState.stack.last?.mixes ?? []
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading) {
				HStack {
					Text("Mixes & Radio")
						.font(.largeTitle)
						.lineLimit(1)
					Spacer()
					LoadingSpinner()
				}
				if !mixes.isEmpty {
					HStack {
						Text("\(mixes.count) \(mixes.count == 1 ? "Mix" : "Mixes")")
						Spacer()
					}
					grid
					footer
				} else if viewState.stack.last?.loadingState == .successful {
					CollectionEmptyState(
						systemImage: "heart",
						message: "You haven't added any mixes yet. Tap the heart icon on any mix or radio to add it to your collection.",
						actionTitle: "View TIDAL's top mixes",
						action: { viewState.push(page: PageTarget(path: "pages/my_collection_my_mixes", title: "Top Mixes")) }
					)
				}
				Spacer(minLength: 0)
			}
			.padding()
		}
		.onReceive(NotificationCenter.default.publisher(for: .collectionMixChanged)) { _ in
			syncFromCache()
		}
	}

	private var grid: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))]) {
			ForEach(mixes) { mix in
				MixGridItem(
					mix: mix,
					session: session,
					player: player,
					showsHeart: true,
					heartIsOn: true,
					onToggleHeart: { viewState.toggleMixInCollection(mix) },
					overlaysTitle: true,
					overlayTitleColor: mix.titleColor.flatMap { Color(hex: $0) },
					overlaySubtitleColor: mix.subtitleColor.flatMap { Color(hex: $0) }
				)
				.onAppear {
					// The last card appearing means the user reached the bottom:
					// fetch the next page.
					guard mix.id == mixes.last?.id else { return }
					Task { await loadMore() }
				}
			}
		}
	}

	@ViewBuilder
	private var footer: some View {
		if viewState.cache.collectionMixesCursor != nil {
			HStack {
				Spacer()
				if loadMoreFailed {
					Button("Try Again") {
						Task { await loadMore() }
					}
				} else {
					LoadingSpinner(.loading)
				}
				Spacer()
			}
			.frame(height: 40)
		}
	}

	/// Appends the next page of collection mixes.
	///
	/// The list is cursor-paged and the cursor is kept in the cache next to the
	/// items. A page that adds nothing new clears the cursor, so a repeated
	/// appearance of the last card can't loop.
	private func loadMore() async {
		guard !isLoadingMore, let cursor = viewState.cache.collectionMixesCursor else { return }
		isLoadingMore = true
		loadMoreFailed = false
		defer { isLoadingMore = false }

		guard let page = await session.collectionMixes(cursor: cursor) else {
			loadMoreFailed = true
			return
		}

		let existing = viewState.cache.collectionMixes ?? []
		var known = Set(existing.map(\.id))
		var appended = existing
		for item in page.items.map(\.data.asMixesItem) where known.insert(item.id).inserted {
			appended.append(item)
		}
		viewState.cache.collectionMixes = appended
		viewState.cache.collectionMixesCursor = appended.count > existing.count ? page.cursor : nil
		syncFromCache()
	}

	/// Copies the shared cache into the current view.
	///
	/// Every heart writes to `cache.collectionMixes` and announces the change,
	/// so this is what makes a removal here (or an add from the top-mixes page)
	/// show up without a refresh round-trip.
	private func syncFromCache() {
		guard viewState.stack.last?.viewType == .collectionMixes,
			  let cached = viewState.cache.collectionMixes else { return }
		viewState.setCurrentMixes(cached)
	}
}

// MARK: - Shared

/// Shown when a filter matches nothing, so the screen never goes blank.
private struct CollectionNoResultsState: View {
	var body: some View {
		CollectionEmptyState(systemImage: "magnifyingglass", message: "No results match your filter.")
	}
}

/// Relative "date added" label: Today / Yesterday / Last week / This month,
/// then an absolute `d MMM yyyy` for anything older.
private func relativeDateAddedString(_ date: Date) -> String {
	let calendar = Calendar.current
	if calendar.isDateInToday(date) { return "Today" }
	if calendar.isDateInYesterday(date) { return "Yesterday" }
	if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), date >= weekAgo {
		return "Last week"
	}
	if calendar.isDate(date, equalTo: Date(), toGranularity: .month) { return "This month" }
	return DateFormatter.collectionDateOnly.string(from: date)
}

extension DateFormatter {
	/// `d MMM yyyy`, e.g. `3 Sep 2026`, for dates older than this month.
	fileprivate static let collectionDateOnly: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "d MMM yyyy"
		return formatter
	}()
}
