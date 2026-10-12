//
//  AlbumView.swift
//  SwiftUI Player
//
//  Created by Melvin Gundlach on 02.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct AlbumView: View {
	let session: Session
	let player: Player

	@Environment(ViewState.self) private var viewState

	@State var cloudPressed: Bool = false
	@State private var isFavorite: Bool? = nil
	@State private var isOffline: Bool = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading) {
				if let album = viewState.stack.last?.album,
				   let tracks = viewState.stack.last?.tracks,
				   let coverUrlSmall = album.getCoverUrl(session: session, resolution: 320),
				   let coverUrlBig = album.getCoverUrl(session: session, resolution: 1280) {
					ZStack(alignment: .bottomTrailing) {
						HStack {
							let cover = ArtworkImage(url: coverUrlSmall, size: 100)
							#if canImport(AppKit)
							Button {
								let controller = ImageWindowController(
									imageUrl: coverUrlBig,
									title: album.title
								)
								controller.window?.title = album.title
								controller.showWindow(nil)
							} label: {
								cover
									.help("Show cover in new window")
							}
							.buttonStyle(.plain)
							.accessibilityLabel("Show cover in new window")
							#else
							cover
								.accessibilityHidden(true)
							#endif

							VStack(alignment: .leading) {
								HStack {
									Text(album.title)
										.font(.title)
										.lineLimit(1)
										.help(album.title)
									if album.hasAttributes {
										album.attributeHStack
											.padding(.leading, -5)
									}
									#if canImport(AppKit)
									Button {
										let controller = ResizableWindowControllerFactory.create(rootView:
											CreditsView(session: session, album: album)
												.environment(viewState)
										)
										controller.window?.title = "Credits – \(album.title)"
										controller.showWindow(nil)
									} label: {
										Image(systemName: "c.circle")
											.accessibilityLabel("Credits")
											.help("Credits")
									}
									.buttonStyle(.plain)
									#endif
									Button {
										if isFavorite ?? false {
											Task {
												print("Remove from Favorites")
												if await session.favorites?.removeAlbum(albumId: album.id) == true {
													isFavorite = false
													viewState.refreshCurrentView()
													NotificationCenter.default.post(name: .favoriteAlbumChanged, object: nil, userInfo: ["albumId": album.id, "isFavorite": false])
												}
											}
										} else {
											Task {
												print("Add to Favorites")
												if await session.favorites?.addAlbum(albumId: album.id) == true {
													isFavorite = true
													viewState.refreshCurrentView()
													NotificationCenter.default.post(name: .favoriteAlbumChanged, object: nil, userInfo: ["albumId": album.id, "isFavorite": true])
												}
											}
										}
									} label: {
										Image(systemName: isFavorite ?? false ? "heart.fill" : "heart")
											.accessibilityLabel("Favorite")
											.accessibilityAddTraits(isFavorite ?? false ? .isSelected : [])
									}
									.buttonStyle(.plain)
									if let url = album.url {
										ShareLink(item: url, preview: SharePreview(album.title)) {
											Image(systemName: "square.and.arrow.up")
												.accessibilityLabel("Share")
												.help("Share")
										}
										.buttonStyle(.plain)
									}
								}
								Text(album.artists?.formArtistString() ?? "")
								if let releaseDate = album.releaseDate {
									Text(DateFormatter.dateOnly.string(from: releaseDate))
								}
							}
							Spacer(minLength: 5)
							VStack(alignment: .leading) {
								if let numberOfTracks = album.numberOfTracks {
									Text("\(numberOfTracks) Tracks")
										.foregroundColor(.secondary)
								}
								if let duration = album.duration {
									Text(secondsToHoursMinutesSecondsString(seconds: duration))
										.foregroundColor(.secondary)
								}
								Spacer()
							}
						}
						Group {
							if cloudPressed && !isOffline {
								Image(systemName: "cloud.fill")
									.resizable()
									.scaledToFit()
									.secondaryIconColor()
							} else {
								Button {
									if isOffline {
										Task {
											print("Remove from Offline")
											await album.removeOffline(session: session)
											cloudPressed = false
											viewState.refreshCurrentView()
											NotificationCenter.default.post(name: .offlineChanged, object: nil)
										}
									} else {
										Task {
											print("Add to Offline")
											cloudPressed = true
											await album.addOffline(session: session)
											// `add(album:)` returns early when the album or track fetch fails, leaving
											// the album unmarked; clear the placeholder and let the re-read decide, so a
											// failed add cannot leave a plain cloud fill with no button behind it.
											cloudPressed = false
											isOffline = await album.isOffline(session: session)
											viewState.refreshCurrentView()
											NotificationCenter.default.post(name: .offlineChanged, object: nil)
										}
									}
								} label: {
									Image(systemName: isOffline ? "cloud.fill" : "cloud")
										.resizable()
										.scaledToFit()
										.accessibilityLabel("Available Offline")
										.accessibilityAddTraits(isOffline ? .isSelected : [])
								}
								.buttonStyle(.plain)
							}
						}
						.frame(width: 30)
					}
					.frame(height: 100)
					.padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))

					TrackList(wrappedTracks: tracks.wrapped(), showCover: false, showAlbumTrackNumber: true,
							  showArtist: true, showAlbum: false, playlist: nil, session: session, player: player,
							  source: QueueSource(type: .album, title: album.title, id: String(album.id)))
				} else {
					HStack {
						Spacer()
					}
				}
				Spacer(minLength: 0)
			}
		}
		.task(id: viewState.stack.last?.album?.id) {
			guard let album = viewState.stack.last?.album else { return }
			// The favourites cache reports nil while it is empty or failed to load, so clear
			// the previous album's answer, then take only a value the library can confirm.
			isFavorite = nil
			if let favorite = await album.isInFavorites(session: session) {
				isFavorite = favorite
			}
			isOffline = await album.isOffline(session: session)
		}
		.onReceive(NotificationCenter.default.publisher(for: .offlineChanged)) { _ in
			guard let album = viewState.stack.last?.album else { return }
			Task { isOffline = await album.isOffline(session: session) }
		}
		.onReceive(NotificationCenter.default.publisher(for: .favoriteAlbumChanged)) { note in
			// The header's own button sets `isFavorite`; this catches the menu-bar
			// command and any other writer, whose `refreshCurrentView()` cannot
			// re-seed a `.task(id:)` whose album id did not change.
			guard let album = viewState.stack.last?.album,
				  note.userInfo?["albumId"] as? Int == album.id else { return }
			Task {
				// Only a confirmed value may replace the shown one; an empty or failed
				// favourites cache returns nil and must not clear a known heart.
				if let favorite = await album.isInFavorites(session: session) {
					isFavorite = favorite
				}
			}
		}
	}
}
