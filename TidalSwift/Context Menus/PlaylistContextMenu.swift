//
//  PlaylistContextMenu.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct PlaylistContextMenu: View {
	let playlist: Playlist
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@EnvironmentObject var playlistEditingValues: PlaylistEditingValues
	@State private var isOffline: Bool = false

	private var source: QueueSource {
		QueueSource(type: .playlist, title: playlist.title, id: playlist.uuid)
	}

	private var isFavorite: Bool {
		viewState.cache.favoritedPlaylistUuids?.contains(playlist.uuid) ?? false
	}

	var body: some View {
		Group {
			Group{
				Button {
					player.add(playlist: playlist, .now, source: source)
				} label: {
					Text("Add Now")
				}
				Button {
					player.add(playlist: playlist, .next, source: source)
				} label: {
					Text("Add Next")
				}
				Button {
					player.add(playlist: playlist, .last, source: source)
				} label: {
					Text("Add Last")
				}
			}
			Divider()
			Group {
				if playlist.creator.id == session.userId { // My playlist
					Button {
						print("Edit Playlist")
						playlistEditingValues.playlist = playlist
						playlistEditingValues.showEditModal = true
					} label: {
						Text("Edit Playlist …")
					}
					Button {
						print("Delete Playlist")
						playlistEditingValues.playlist = playlist
						playlistEditingValues.showDeleteModal = true
					} label: {
						Text("Delete Playlist …")
					}
				} else {
					if isFavorite {
						Button {
							Task {
								print("Remove from Favorites")
								if await session.favorites?.removePlaylist(playlistId: playlist.uuid) == true {
									viewState.cache.favoritedPlaylistUuids?.remove(playlist.uuid)
									NotificationCenter.default.post(name: .favoritePlaylistChanged, object: nil)
								}
							}
						} label: {
							Text("Remove from Favorites")
						}
					} else {
						Button {
							Task {
								print("Add to Favorites")
								if await session.favorites?.addPlaylist(playlistId: playlist.uuid) == true {
									viewState.cache.favoritedPlaylistUuids?.insert(playlist.uuid)
									NotificationCenter.default.post(name: .favoritePlaylistChanged, object: nil)
								}
							}
						} label: {
							Text("Add to Favorites")
						}
					}
				}
				Button {
					Task {
						print("Add \(playlist.title) to Playlist")
						if let tracks = await session.playlistTracks(playlistId: playlist.uuid) {
							playlistEditingValues.tracks = tracks
							playlistEditingValues.showAddTracksModal = true
						}
					}
				} label: {
					Text("Add to Playlist …")
				}
			}
			Divider()
			Group {
				if isOffline {
					Button {
						Task {
							print("Remove from Offline")
							await playlist.removeOffline(session: session)
							isOffline = false
							viewState.refreshCurrentView()
						}
					} label: {
						Text("Remove from Offline")
					}
				} else {
					Button {
						Task {
							print("Add to Offline")
							await playlist.addOffline(session: session)
							isOffline = true
							viewState.refreshCurrentView()
						}
					} label: {
						Text("Add to Offline")
					}
				}

				Button {
					Task {
						print("Download")
						_ = await session.helpers.download.download(playlist: playlist)
					}
				} label: {
					Text("Download")
				}
			}
			Divider()
			Group {
				#if canImport(AppKit)
				if let imageUrl = playlist.imageUrl(session: session, resolution: 750) {
					Button {
						print("Image")
						let controller = ImageWindowController(
							imageUrl: imageUrl,
							title: playlist.title
						)
						controller.window?.title = playlist.title
						controller.showWindow(nil)
					} label: {
						Text("Image")
					}
				}
				#endif
				Button {
					print("Share Playlist")
					Pasteboard.copy(string: playlist.url.absoluteString)
				} label: {
					Text("Copy URL")
				}
			}
		}
		.task(id: playlist.uuid) {
			isOffline = await playlist.isOffline(session: session)
		}
	}
}
