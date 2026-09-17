//
//  MasterDetailView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 20.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import AppKit
import Combine
import TidalSwiftLib

extension Notification.Name {
	static let focusSearchField = Notification.Name("de.melgu.TidalSwift.focusSearchField")
	static let favoriteTrackChanged = Notification.Name("de.melgu.TidalSwift.favoriteTrackChanged")
	static let favoritePlaylistChanged = Notification.Name("de.melgu.TidalSwift.favoritePlaylistChanged")
}

struct TopDetailView: View {
    let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@EnvironmentObject var appModel: TidalSwiftAppModel

	@State private var columnVisibility: NavigationSplitViewVisibility = .all

	init(session: Session, player: Player) {
		self.session = session
		self.player = player
	}

	var body: some View {
		let selectionBinding = Binding<SidebarSelection?>(
			get: {
				if let playlist = viewState.stack.last?.playlist {
					return .playlist(playlist)
				}
				if let viewType = viewState.stack.last?.viewType {
					return .view(viewType)
				}
				return nil
			},
			set: { newValue in
				Task {
					viewState.clearStack()
					switch newValue {
					case .view(let viewType):
						viewState.push(view: TidalSwiftView(viewType: viewType))
					case .playlist(let playlist):
						viewState.push(playlist: playlist)
					case nil:
						break
					}
				}
			})
		return VStack(spacing: 0) {
			HStack(spacing: 0) {
				NavigationSplitView(columnVisibility: $columnVisibility) {
					TopView(selection: selectionBinding, session: session)
						.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
				} detail: {
					ZStack {
						// Disabled until the Now Playing drawer is built.
						// NowPlayingAmbientLayer()

						VStack(spacing: 0) {
							TopBar()
							DetailView(session: session, player: player)
						}
					}
					.frame(minWidth: 850)
					// Clicking empty space resigns first responder so the toolbar search
					// field loses focus. Controls keep priority over this container tap.
					.contentShape(Rectangle())
					.onTapGesture {
						NSApp.keyWindow?.makeFirstResponder(nil)
					}
					// Opaque background + clipping keep the detail column's scrolling
					// content from showing through the translucent sidebar.
					.background(Color(nsColor: .windowBackgroundColor))
					.clipped()
					.toolbar {
						ToolbarItem(placement: .navigation) {
							navigationControls
						}
					}
				}
				.searchable(text: $viewState.searchTerm, placement: .toolbar, prompt: "Search")
				.onSubmit(of: .search) {
					submitSearch()
				}
				.onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
					focusToolbarSearchField()
				}

				// Docked queue panel: sits beside the content (not over it), spanning
				// from below the toolbar down to the play bar.
				if appModel.showQueuePanel {
					Divider()
					QueuePanel(session: session, player: player)
						.transition(.move(edge: .trailing))
				}
			}
			Divider()
			PlayerInfoView(session: session, player: player)
		}
		.frame(minHeight: 500)
	}

	// MARK: - Toolbar Navigation

	private var navigationControls: some View {
		HStack(spacing: 6) {
			Button {
				viewState.back()
			} label: {
				Image(systemName: "chevron.left")
					.font(.system(size: 11, weight: .bold))
					.frame(width: 26, height: 26)
					.background(Circle().fill(Color.secondary.opacity(viewState.canGoBack ? 0.12 : 0.05)))
					.foregroundStyle(viewState.canGoBack ? Color.primary : Color.secondary)
					.contentShape(Circle())
			}
			.buttonStyle(.plain)
			.disabled(!viewState.canGoBack)
			.help("Back")
			.accessibilityLabel("Back")

			Button {
				viewState.forward()
			} label: {
				Image(systemName: "chevron.right")
					.font(.system(size: 11, weight: .bold))
					.frame(width: 26, height: 26)
					.background(Circle().fill(Color.secondary.opacity(viewState.canGoForward ? 0.12 : 0.05)))
					.foregroundStyle(viewState.canGoForward ? Color.primary : Color.secondary)
					.contentShape(Circle())
			}
			.buttonStyle(.plain)
			.disabled(!viewState.canGoForward)
			.help("Forward")
			.accessibilityLabel("Forward")
		}
	}

	// MARK: - Search

	private func submitSearch() {
		guard !viewState.searchTerm.isEmpty else { return }
		if viewState.stack.last?.viewType == .search {
			viewState.doSearch(term: viewState.searchTerm)
		} else {
			viewState.push(view: TidalSwiftView(viewType: .search))
		}
	}

	private func focusToolbarSearchField() {
		guard let toolbar = NSApp.keyWindow?.toolbar else { return }
		for item in toolbar.items {
			if let searchItem = item as? NSSearchToolbarItem {
				searchItem.beginSearchInteraction()
			}
		}
	}
}

enum SidebarSelection: Hashable {
	case view(ViewType)
	case playlist(Playlist)
}

struct TopView: View {
	@Binding var selection: SidebarSelection?

	let session: Session

	@EnvironmentObject var viewState: ViewState

	@State private var allPlaylists: [Playlist] = []
	@State private var favoritedPlaylistUuids: Set<String> = []
	@State private var loadingState: LoadingState = .loading
	@State private var isLoggedIn: Bool = true

	var body: some View {
		VStack {
			List(selection: $selection) {
				Section {
					Label("Music", systemImage: "music.note")
						.tag(SidebarSelection.view(.music))
					Label("Explore", systemImage: "safari")
						.tag(SidebarSelection.view(.explore))
						.disabled(true)
						.selectionDisabled()
						.help("Coming soon")
						.listRowBackground(Color.clear)
					Label("Feed", systemImage: "dot.radiowaves.left.and.right")
						.tag(SidebarSelection.view(.feed))
						.disabled(true)
						.selectionDisabled()
						.help("Coming soon")
						.listRowBackground(Color.clear)
					Label("Collection", systemImage: "square.stack")
						.tag(SidebarSelection.view(.collection))
						.disabled(true)
						.selectionDisabled()
						.help("Coming soon")
						.listRowBackground(Color.clear)
					DisclosureGroup {
						Label("Albums", systemImage: "square.stack")
							.tag(SidebarSelection.view(.offlineAlbums))
						Label("Tracks", systemImage: "music.note.list")
							.tag(SidebarSelection.view(.offlineTracks))
					} label: {
						Label("Offline", systemImage: "arrow.down.circle")
					}
					.listRowBackground(Color.clear)
				}

				Section {
					if loadingState == .loading {
						HStack(spacing: 8) {
							LoadingSpinner(.loading)
							Text("Loading playlists…")
								.foregroundColor(.secondary)
						}
						.padding(.vertical, 4)
						.selectionDisabled()
						.listRowBackground(Color.clear)
					} else if !isLoggedIn {
						SidebarMessageRow(
							title: "Not logged in",
							message: "Log in to see your playlists."
						)
						.listRowBackground(Color.clear)
					} else if allPlaylists.isEmpty {
						SidebarMessageRow(
							title: "No playlists yet",
							message: "Playlists you create or favorite will appear here."
						)
						.listRowBackground(Color.clear)
					} else {
						ForEach(allPlaylists) { playlist in
							SidebarPlaylistRow(
								playlist: playlist,
								session: session,
								isSelected: selection == .playlist(playlist),
								isFavorite: favoritedPlaylistUuids.contains(playlist.uuid)
							)
							.tag(SidebarSelection.playlist(playlist))
						}
					}
				} header: {
					HStack {
						Text("All playlists")
						Spacer()
						Image(systemName: "plus")
							.help("Create playlist (coming soon)")
						Image(systemName: "arrow.up.arrow.down")
							.help("Sort playlists (coming soon)")
					}
					.listRowBackground(Color.clear)
				}
			}
			.listStyle(SidebarListStyle())
		}
		.task(id: session.userId) {
			isLoggedIn = session.userId != nil
			guard isLoggedIn else {
				loadingState = .successful
				return
			}
			allPlaylists = viewState.cache.allPlaylists ?? []
			favoritedPlaylistUuids = viewState.cache.favoritedPlaylistUuids ?? []
			loadingState = allPlaylists.isEmpty ? .loading : .successful
			let result = await viewState.refreshAllPlaylists()
			allPlaylists = result.playlists
			favoritedPlaylistUuids = result.favoritedUuids
			loadingState = .successful
			NotificationCenter.default.post(name: .favoritePlaylistChanged, object: nil)
		}
		.onReceive(NotificationCenter.default.publisher(for: .favoritePlaylistChanged)) { _ in
			favoritedPlaylistUuids = viewState.cache.favoritedPlaylistUuids ?? []
		}
	}
}

private struct SidebarMessageRow: View {
	let title: String
	let message: String

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title)
				.font(.callout)
				.fontWeight(.medium)
			Text(message)
				.font(.caption)
				.foregroundColor(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.padding(.vertical, 4)
		.selectionDisabled()
	}
}

struct DetailView: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	init(session: Session, player: Player) {
		self.session = session
		self.player = player
		print("init DetailView")
	}

	var emptyStateView: some View {
		ContentUnavailableView {
			Label("Nothing Selected", systemImage: "sidebar.left")
		} description: {
			Text("Choose an item from the sidebar to get started.")
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	var body: some View {
		VStack(spacing: 0) {
			Group {
				if let viewType = viewState.stack.last?.viewType {
					Group {
						// Primary
						if viewType == .music {
							MusicHomeView(session: session, player: player)
						} else if viewType == .explore {
							ComingSoonView(title: "Explore")
						} else if viewType == .feed {
							ComingSoonView(title: "Feed")
						} else if viewType == .collection {
							ComingSoonView(title: "Collection")
						}

						// Search
						else if viewType == .search {
							SearchView(session: session, player: player)
						}

						// News
						else if viewType == .newReleases {
							NewReleases(session: session, player: player)
						} else if viewType == .myMixes {
							MyMixes(session: session, player: player)
						}

						// Favorites
						else if viewType == .favoritePlaylists {
							FavoritePlaylists(session: session, player: player)
						} else if viewType == .favoriteAlbums {
							FavoriteAlbums(session: session, player: player)
						} else if viewType == .favoriteTracks {
							FavoriteTracks(session: session, player: player)
						} else if viewType == .favoriteVideos {
							FavoriteVideos(session: session, player: player)
						} else if viewType == .favoriteArtists {
							FavoriteArtists(session: session, player: player)
						}

						else if viewType == .offlinePlaylists {
							OfflinePlaylistsView(session: session, player: player)
						} else if viewType == .offlineAlbums {
							OfflineAlbumsView(session: session, player: player)
						} else if viewType == .offlineTracks {
							OfflineTracksView(session: session, player: player)
						}

						// Single Things
						else if viewType == .artist {
							ArtistView(session: session, player: player, viewState: viewState)
						} else if viewType == .album {
							AlbumView(session: session, player: player)
						} else if viewType == .playlist {
							PlaylistView(session: session, player: player)
						} else if viewType == .mix {
							MixPlaylistView(session: session, player: player)
						} else if viewType == .viewAll {
							if let target = viewState.stack.last?.viewAllTarget {
								ViewAllPage(target: target, session: session, player: player)
							}
						}
					}
				} else {
					emptyStateView
				}
			}
		}
	}
}

struct ComingSoonView: View {
	let title: String

	var body: some View {
		ContentUnavailableView {
			Label(title, systemImage: "hammer")
		} description: {
			Text("Coming soon.")
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
