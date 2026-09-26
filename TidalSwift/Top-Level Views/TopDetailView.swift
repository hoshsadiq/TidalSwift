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
	static let focusSearchField = Notification.Name("io.hosh.TidalSwift.focusSearchField")
	static let favoriteTrackChanged = Notification.Name("io.hosh.TidalSwift.favoriteTrackChanged")
	static let favoritePlaylistChanged = Notification.Name("io.hosh.TidalSwift.favoritePlaylistChanged")
}

struct TopDetailView: View {
    let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@EnvironmentObject var appModel: TidalSwiftAppModel
	@EnvironmentObject var playbackInfo: PlaybackInfo
	@Environment(\.colorScheme) private var colorScheme

	@State private var columnVisibility: NavigationSplitViewVisibility = .all
	/// `.searchable` owns the field, so its width cap is applied through AppKit.
	@State private var searchFieldWidthConstraint: NSLayoutConstraint?

	private static let searchFieldWidth: CGFloat = 200

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
			ZStack(alignment: .trailing) {
				HStack(spacing: 0) {
					NavigationSplitView(columnVisibility: $columnVisibility) {
						TopView(selection: selectionBinding, session: session)
							.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
							// Hides the system sidebar toggle while the drawer covers
							// the sidebar; `nil` restores it when the drawer closes.
							.toolbar(removing: playbackInfo.isNowPlayingExpanded ? .sidebarToggle : nil)
					} detail: {
						detailColumn
					}
					.searchable(text: $viewState.searchTerm, placement: .toolbar, prompt: "Search")
					.onSubmit(of: .search) {
						submitSearch()
					}
					.onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
						focusToolbarSearchField()
					}

					// Reserves the queue panel's width so the content does not
					// slide under the overlay below while the drawer is closed.
					if appModel.showQueuePanel && !playbackInfo.isNowPlayingExpanded {
						Color.clear.frame(width: 300)
					}
				}

				// Now Playing drawer: covers the sidebar and content while the
				// bar below stays visible. The ambient layer sits behind the
				// drawer content.
				if playbackInfo.isNowPlayingExpanded {
					// Stays fully opaque while the drawer slides down, then fades
					// once the slide has finished, so the background does not
					// disappear before the drawer has left the screen.
					NowPlayingAmbientLayer(session: session)
						.transition(.asymmetric(
							insertion: .opacity,
							removal: .opacity.animation(.easeInOut(duration: 0.15).delay(0.3))
						))
				NowPlayingDrawer(session: session, player: player)
					.padding(.trailing, appModel.showQueuePanel ? 300 : 0)
					.animation(nil, value: appModel.showQueuePanel)
					.transition(.move(edge: .bottom))
					.zIndex(1)
					.ignoresSafeArea()
				}

				// Queue panel above the drawer so the ambient reads through its
				// translucent material.
				if appModel.showQueuePanel {
					HStack(spacing: 0) {
						Divider()
						QueuePanel(session: session, player: player)
					}
					.frame(maxHeight: .infinity)
					.transition(.move(edge: .trailing))
					.zIndex(2)
				}
			}
			.animation(.easeInOut(duration: 0.3), value: playbackInfo.isNowPlayingExpanded)
			Divider()
			// The bar owns its background: opaque so the drawer's downward slide
			// passes behind it, and while the drawer is expanded it adopts the
			// drawer's ambient colour (see `PlayerInfoView`). The colour scheme
			// that keeps its labels readable on that wash is applied here.
			PlayerInfoView(session: session, player: player)
				.environment(\.colorScheme, playerBarColorScheme)
				.animation(.easeInOut(duration: 0.3), value: playbackInfo.isNowPlayingExpanded)
		}
		.frame(minHeight: 500)
		.onChange(of: playbackInfo.isNowPlayingExpanded) { _, isExpanded in
			updateSearchFieldLayout()
			// Collapsing the drawer always leaves fullscreen, so the window can
			// never be left fullscreen without the drawer.
			guard !isExpanded else { return }
			guard let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) else { return }
			window.toggleFullScreen(nil)
		}
		.onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
			guard let window = notification.object as? NSWindow, window.isMainWindow || window.isKeyWindow else { return }
			playbackInfo.isFullscreen = true
		}
		.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
			guard let window = notification.object as? NSWindow, window.isMainWindow || window.isKeyWindow else { return }
			playbackInfo.isFullscreen = false
		}
		.onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
			guard let window = notification.object as? NSWindow, window.isMainWindow || window.isKeyWindow else { return }
			// A new window must not inherit the closed window's fullscreen state.
			playbackInfo.isFullscreen = false
		}
		.task(id: playbackInfo.isNowPlayingExpanded) {
			updateSearchFieldLayout()
		}
	}

	// MARK: - Detail Column

	/// The scheme the player bar renders in. Collapsed, it follows the window;
	/// expanded, it contrasts with the ambient wash it now sits on.
	private var playerBarColorScheme: ColorScheme {
		guard playbackInfo.isNowPlayingExpanded else { return colorScheme }
		return NowPlayingAmbient.contrastingForeground(for: playbackInfo.ambientColor) == .black ? .light : .dark
	}

	/// The detail column: routed content plus the toolbar items. Extracted so the
	/// drawer can be layered over the whole content row in `body`.
	private var detailColumn: some View {
		DetailView(session: session, player: player)
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
			.navigationTitle(playbackInfo.isNowPlayingExpanded ? "" : "TidalSwift")
			.toolbar {
				// While the drawer is expanded the toolbar hosts the drawer's own
				// action cluster in place of the account button, and the
				// back/forward controls are hidden so only those controls remain.
				if !playbackInfo.isNowPlayingExpanded {
					ToolbarItem(id: "navigationControls", placement: .navigation) {
						navigationControls
					}
				}
				if playbackInfo.isNowPlayingExpanded {
					// The cluster floats directly on the ambient wash, so it opts
					// out of the system's shared glass background.
					ToolbarItem(id: "nowPlayingCluster", placement: .primaryAction) {
						NowPlayingToolbarCluster()
							.environment(\.colorScheme, playerBarColorScheme)
					}
					.withoutToolbarSharedBackground()
				} else {
					ToolbarItem(id: "accountButton", placement: .primaryAction) {
						accountButton
					}
				}
			}
			// Keep the window toolbar fully transparent while expanded so the
			// drawer's ambient wash reaches the top of the window.
			.modifier(WindowToolbarBackgroundVisibility(isHidden: playbackInfo.isNowPlayingExpanded))
	}

	/// Pins the toolbar search field to a fixed width.
	///
	/// The field is owned by `.searchable`, so the width is capped through
	/// AppKit: `NSSearchToolbarItem` otherwise stretches the field to absorb
	/// toolbar slack. A constant width keeps it clear of the queue panel and
	/// stops it jumping when the queue opens or closes.
	private func updateSearchFieldLayout() {
		guard let toolbar = NSApp.keyWindow?.toolbar else { return }
		for case let searchItem as NSSearchToolbarItem in toolbar.items {
			capSearchField(searchItem)
		}
	}

	private func capSearchField(_ item: NSSearchToolbarItem) {
		let field = item.searchField
		let isExpanded = playbackInfo.isNowPlayingExpanded
		// The drawer slides under the titlebar, so a visible search field would
		// float over its content. Hiding the field view alone is not enough:
		// the search item is the toolbar's trailing-most item, so the drawer's
		// cluster is laid out to its left. If the item keeps its previous width
		// (the field is not capped until the drawer first expands), the cluster
		// lands at a different x on every toolbar rebuild, so it jumps between
		// open/close cycles. On macOS 15+ hide the whole item so it leaves the
		// toolbar layout and the cluster stays pinned to the trailing edge.
		// Older systems fall back to hiding the field view.
		if #available(macOS 15.0, *) {
			item.isHidden = isExpanded
		}
		field.isHidden = isExpanded

		let width = isExpanded ? 0 : Self.searchFieldWidth
		if let constraint = searchFieldWidthConstraint, constraint.firstItem as? NSView === field {
			constraint.constant = width
		} else {
			let constraint = field.widthAnchor.constraint(lessThanOrEqualToConstant: width)
			constraint.isActive = true
			searchFieldWidthConstraint = constraint
		}
		item.preferredWidthForSearchField = isExpanded ? 0 : Self.searchFieldWidth
	}

	// MARK: - Toolbar Items

	private var accountButton: some View {
		Button {
			appModel.accountInfo()
		} label: {
			Image(systemName: "person.crop.circle")
		}
		.help("Account")
		.accessibilityLabel("Account")
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

/// Hides the window toolbar's background so the drawer's ambient wash reaches
/// the top of the window. Uses the macOS 15+ API when available; the older
/// `toolbarBackground(_:for:)` is the same behaviour (it was renamed).
private struct WindowToolbarBackgroundVisibility: ViewModifier {
	let isHidden: Bool

	@ViewBuilder
	func body(content: Content) -> some View {
		if #available(macOS 15.0, *) {
			content.toolbarBackgroundVisibility(isHidden ? .hidden : .automatic, for: .windowToolbar)
		} else {
			content.toolbarBackground(isHidden ? .hidden : .automatic, for: .windowToolbar)
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

	/// "Show all collection items directly in the sidebar instead of a submenu."
	/// On (the default) the Collection destinations are flat rows under a small
	/// "Collection" header; off they hide behind a disclosure group.
	@AppStorage("ShowCollectionInSidebar") private var showCollectionInSidebar = true

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
					Label("Feed", systemImage: "dot.radiowaves.left.and.right")
						.tag(SidebarSelection.view(.feed))
					if showCollectionInSidebar {
						Text("Collection")
							.font(.caption)
							.foregroundColor(.secondary)
							.selectionDisabled()
							.listRowBackground(Color.clear)
						collectionRows
					} else {
						DisclosureGroup {
							collectionRows
						} label: {
							Label("Collection", systemImage: "square.stack")
						}
						.listRowBackground(Color.clear)
					}
					// Offline screens stay routed for persisted navigation stacks.
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

	@ViewBuilder
	private var collectionRows: some View {
		Label("Mixes & Radio", systemImage: "antenna.radiowaves.left.and.right")
			.tag(SidebarSelection.view(.collectionMixes))
		Label("Playlists", systemImage: "list.bullet")
			.tag(SidebarSelection.view(.collectionPlaylists))
		Label("Albums", systemImage: "opticaldisc")
			.tag(SidebarSelection.view(.collectionAlbums))
		Label("Tracks", systemImage: "music.note")
			.tag(SidebarSelection.view(.collectionTracks))
		Label("Videos", systemImage: "play.rectangle")
			.tag(SidebarSelection.view(.collectionVideos))
		Label("Profiles", systemImage: "person.crop.circle")
			.tag(SidebarSelection.view(.collectionProfiles))
		Label("Purchases", systemImage: "tag")
			.disabled(true)
			.selectionDisabled()
			.help("Coming soon")
			.listRowBackground(Color.clear)
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
							ExploreView(session: session, player: player)
						} else if viewType == .feed {
							FeedView(session: session, player: player)
						} else if viewType == .collection {
							ComingSoonView(title: "Collection")
						}

						// Search
						else if viewType == .search {
							SearchView(session: session, player: player)
						}

						// Collection
						else if viewType == .collectionMixes {
							CollectionMixes(session: session, player: player)
						} else if viewType == .collectionPlaylists || viewType == .favoritePlaylists {
							CollectionPlaylists(session: session, player: player)
						} else if viewType == .collectionAlbums || viewType == .favoriteAlbums {
							CollectionAlbums(session: session, player: player)
						} else if viewType == .collectionTracks || viewType == .favoriteTracks {
							CollectionTracks(session: session, player: player)
						} else if viewType == .collectionVideos || viewType == .favoriteVideos {
							CollectionVideos(session: session, player: player)
						} else if viewType == .collectionProfiles || viewType == .favoriteArtists {
							CollectionProfiles(session: session, player: player)
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
						} else if viewType == .page {
							if let target = viewState.stack.last?.pageTarget {
								PageView(target: target, session: session, player: player)
									.id(target.path)
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
