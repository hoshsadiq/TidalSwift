//
//  PlaylistView.swift
//  SwiftUI Player
//
//  Created by Melvin Gundlach on 02.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct PlaylistView: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@State private var isFavorite: Bool? = nil
	@State private var isOffline: Bool = false

	var isUserPlaylist: Bool {
		viewState.stack.last?.playlist?.creator.id == session.userId
	}

	var body: some View {
		ScrollView {
			VStack(alignment: .leading) {
				if let tracks = viewState.stack.last?.tracks,
				   let playlist = viewState.stack.last?.playlist,
		   let imageUrlSmall = playlist.imageUrl(session: session, resolution: 320),
		   let imageUrlBig = playlist.imageUrl(session: session, resolution: 750) {
					ZStack(alignment: .bottomTrailing) {
						HStack {
							AsyncImage(url: imageUrlSmall) { image in
								image.resizable().scaledToFit()
							} placeholder: {
								Rectangle()
							}
							.aspectRatio(contentMode: .fill)
							.frame(width: 100, height: 100)
							.contentShape(Rectangle())
							.clipped()
							.cornerRadius(CORNERRADIUS)
							.shadow(radius: SHADOWRADIUS, y: SHADOWY)
							.help("Show image in new window")
							#if canImport(AppKit)
							.onTapGesture {
								let controller = ImageWindowController(
									imageUrl: imageUrlBig,
									title: playlist.title
								)
								controller.window?.title = playlist.title
								controller.showWindow(nil)
							}
							#endif
							.accessibilityHidden(true)

							VStack(alignment: .leading) {
								HStack {
									Text(playlist.title)
										.font(.title)
										.lineLimit(2)
									if isFavorite == true {
										Image(systemName: "heart.fill")
											.onTapGesture {
												Task {
													print("Remove from Favorites")
													if await session.favorites?.removePlaylist(playlistId: playlist.uuid) == true {
														isFavorite = false
														viewState.cache.favoritedPlaylistUuids?.remove(playlist.uuid)
														NotificationCenter.default.post(name: .favoritePlaylistChanged, object: nil)
														viewState.refreshCurrentView()
													}
												}
											}
									} else {
										Image(systemName: "heart")
											.onTapGesture {
												Task {
													print("Add to Favorites")
													if await session.favorites?.addPlaylist(playlistId: playlist.uuid) == true {
														isFavorite = true
														viewState.cache.favoritedPlaylistUuids?.insert(playlist.uuid)
														NotificationCenter.default.post(name: .favoritePlaylistChanged, object: nil)
														viewState.refreshCurrentView()
													}
												}
											}
									}
									Image(systemName: "square.and.arrow.up")
										.onTapGesture {
											Pasteboard.copy(string: playlist.url.absoluteString)
										}
								}
								Text(playlist.description ?? "")
								Text(playlist.creator.name ?? "")
								Text("Created: \(DateFormatter.dateOnly.string(from: playlist.created))")
									.foregroundColor(.secondary)
								Text("Last updated: \(DateFormatter.dateOnly.string(from: playlist.lastUpdated))")
									.foregroundColor(.secondary)
							}
							Spacer(minLength: 5)
								.layoutPriority(-1)
							VStack(alignment: .leading) {
								Text("\(playlist.numberOfTracks) Tracks")
									.foregroundColor(.secondary)
								Text(secondsToHoursMinutesSecondsString(seconds: playlist.duration))
									.foregroundColor(.secondary)
								Spacer()
							}
						}
				if isOffline {
					Image(systemName: "cloud.fill")
						.resizable()
						.scaledToFit()
						.frame(width: 30)
						.onTapGesture {
							Task {
								print("Remove from Offline")
								await playlist.removeOffline(session: session)
								isOffline = false
								viewState.refreshCurrentView()
							}
						}
				} else {
					Image(systemName: "cloud")
						.resizable()
						.scaledToFit()
						.frame(width: 30)
						.onTapGesture {
							Task {
								print("Add to Offline")
								await playlist.addOffline(session: session)
								isOffline = true
								viewState.refreshCurrentView()
							}
						}
				}
					}
					.frame(height: 100)
					.padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))

					TrackList(wrappedTracks: tracks.wrapped(), showCover: true, showAlbumTrackNumber: false,
							  showArtist: true, showAlbum: true, playlist: isUserPlaylist ? playlist : nil,
							  session: session, player: player,
							  source: QueueSource(type: .playlist, title: playlist.title, id: playlist.uuid))
				} else {
					HStack {
						Spacer()
					}
				}

				Spacer(minLength: 0)
			}
		}
		.task(id: viewState.stack.last?.playlist?.uuid) {
			guard let playlist = viewState.stack.last?.playlist else { return }
			isFavorite = viewState.cache.favoritedPlaylistUuids?.contains(playlist.uuid)
			isOffline = await playlist.isOffline(session: session)
		}
		.onReceive(NotificationCenter.default.publisher(for: .favoritePlaylistChanged)) { _ in
			guard let playlist = viewState.stack.last?.playlist else { return }
			isFavorite = viewState.cache.favoritedPlaylistUuids?.contains(playlist.uuid)
		}
	}
}
