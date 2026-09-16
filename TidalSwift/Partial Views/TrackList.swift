//
//  TrackList.swift
//  SwiftUI Player
//
//  Created by Melvin Gundlach on 02.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import Combine
import TidalSwiftLib

struct TrackList: View {
	let wrappedTracks: [WrappedTrack]
	let showCover: Bool
	let showAlbumTrackNumber: Bool
	let showArtist: Bool
	let showAlbum: Bool
	let playlist: Playlist? // Has to be nil if not displaying User Playlist
	let session: Session
	let player: Player
	var source: QueueSource?

	@State private var selectedTrackId: Int?
	@State private var hoveringTrackId: Int?
	@FocusState private var focusedTrackId: Int?

	var body: some View {
		LazyVStack {
			ForEach(wrappedTracks) { wrappedTrack in
				TrackRow(track: wrappedTrack.track, showCover: showCover, showArtist: showArtist, showAlbum: showAlbum,
						 trackNumber: showAlbumTrackNumber ? nil : wrappedTrack.id, session: session)
				.padding(.horizontal, 8)
				.background(
					RoundedRectangle(cornerRadius: CORNERRADIUS)
						.fill(rowBackground(for: wrappedTrack.id))
						.padding(.vertical, -8)
				)
				.padding(.horizontal, 10)
				.contentShape(Rectangle())
				.onHover { hovering in
					if hovering {
						hoveringTrackId = wrappedTrack.id
					} else if hoveringTrackId == wrappedTrack.id {
						hoveringTrackId = nil
					}
				}
				.onTapGesture(count: 2) {
					if wrappedTrack.track.isUnavailable { return }
					print("\(wrappedTrack.track.id) \(wrappedTrack.track.title)")
					player.add(tracks: wrappedTracks.unwrapped(), .now, playAt: wrappedTrack.id, source: source)
				}
				.onTapGesture(count: 1) {
					selectedTrackId = wrappedTrack.id
					focusedTrackId = wrappedTrack.id
				}
				.contextMenu {
					TrackContextMenu(track: wrappedTrack.track, indexInPlaylist: playlist != nil ? wrappedTrack.id : nil, playlist: playlist, session: session, player: player)
				}
				.focusable()
				.focused($focusedTrackId, equals: wrappedTrack.id)
				.focusEffectDisabled()
				.onKeyPress(.upArrow) {
					moveFocus(from: wrappedTrack.id, by: -1)
					return .handled
				}
				.onKeyPress(.downArrow) {
					moveFocus(from: wrappedTrack.id, by: 1)
					return .handled
				}
				Divider()
					.padding(.horizontal, 18)
			}
		}
		.onChange(of: focusedTrackId) { _, newValue in
			// Keyboard focus and selection are unified, like an NSTableView: moving
			// focus with Tab or the arrow keys also moves the selection highlight.
			if let newValue {
				selectedTrackId = newValue
			}
		}
	}

	private func rowBackground(for trackId: Int) -> Color {
		if selectedTrackId == trackId {
			return Color.controlAccentColor.opacity(0.25)
		}
		if hoveringTrackId == trackId {
			return Color.primary.opacity(0.08)
		}
		return .clear
	}

	private func moveFocus(from trackId: Int, by offset: Int) {
		guard let index = wrappedTracks.firstIndex(where: { $0.id == trackId }) else { return }
		let newIndex = index + offset
		guard wrappedTracks.indices.contains(newIndex) else { return }
		let newId = wrappedTracks[newIndex].id
		focusedTrackId = newId
		selectedTrackId = newId
	}
}

struct TrackRow: View {
	let track: Track
	let showCover: Bool
	let showArtist: Bool
	let showAlbum: Bool
	let trackNumber: Int?
	let session: Session

	var widthFactorTrack: CGFloat
	var widthFactorArtist: CGFloat
	var widthFactorAlbum: CGFloat

	@EnvironmentObject var viewState: ViewState
	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var playbackInfo: PlaybackInfo
	@State private var isOffline: Bool = false
	@State private var isFavorite: Bool? = nil

	init(track: Track, showCover: Bool = false, showArtist: Bool, showAlbum: Bool,
		 trackNumber: Int? = nil, session: Session) {
		self.track = track
		self.showCover = showCover
		self.showArtist = showArtist
		self.showAlbum = showAlbum
		if let trackNumber = trackNumber {
			self.trackNumber = trackNumber + 1 // To start counting from 1
		} else {
			self.trackNumber = nil
		}
		self.session = session

		if showArtist && showAlbum { // Both
			self.widthFactorTrack = 0.28
			self.widthFactorArtist = 0.28
			self.widthFactorAlbum = 0.28
		} else if showArtist != showAlbum { // One
			self.widthFactorTrack = 0.40
			self.widthFactorArtist = 0.40
			self.widthFactorAlbum = 0.40
		} else { // None
			self.widthFactorTrack = 0.66
			self.widthFactorArtist = 0.0
			self.widthFactorAlbum = 0.0
		}
	}

	var body: some View {
		GeometryReader { metrics in
			HStack {
				HStack {
					HStack {
						if !queueInfo.queue.isEmpty &&
							queueInfo.queue[queueInfo.currentIndex].track == track {
							Image(systemName: "play.fill")
								.secondaryIconColor()
						}
						if showCover {
							if let coverUrl = track.getCoverUrl(session: session, resolution: 80) {
								AsyncImage(url: coverUrl) { image in
									image.resizable().scaledToFit()
								} placeholder: {
									Rectangle()
								}
								.frame(width: 30, height: 30)
								.cornerRadius(CORNERRADIUS)
								.accessibilityHidden(true)
							} else {
								Rectangle()
									.foregroundColor(.black)
									.frame(width: 30, height: 30)
									.cornerRadius(CORNERRADIUS)
							}
						} else {
							Text("\(trackNumber ?? track.trackNumber)")
								.fontWeight(.thin)
								.foregroundColor(.secondary)
						}
						Text(track.title)
						if let version = track.version {
							Text(version)
								.foregroundColor(.secondary)
								.padding(.leading, -5)
								.layoutPriority(-1)
						}
						track.attributeHStack
							.padding(.leading, -5)
							.layoutPriority(1)
						Spacer(minLength: 5)
					}
					.frame(width: metrics.size.width * widthFactorTrack)
					.help(trackToolTipString)
					if showArtist {
						HStack {
							Text(track.artists.formArtistString())
							Spacer(minLength: 5)
						}
						.frame(width: metrics.size.width * widthFactorArtist)
						.help(track.artists.formArtistString())
					}
					if showAlbum {
						HStack {
							Text(track.album.title)
							Spacer(minLength: 5)
						}
						.frame(width: metrics.size.width * widthFactorAlbum)
						.help(track.album.title)
					}
				}
				Group {
					Text(secondsToHoursMinutesSecondsString(seconds: track.duration))
					Spacer()
					if isOffline {
						Image(systemName: "cloud.fill")
							.secondaryIconColor()
					}
					#if canImport(AppKit)
					Image(systemName: "c.circle")
						.onTapGesture {
							let controller = ResizableWindowControllerFactory.create(rootView:
								CreditsView(session: session, track: track)
								.environmentObject(viewState)
							)
							controller.window?.title = "Credits – \(track.title)"
							controller.showWindow(nil)
						}
					#endif
				if isFavorite ?? false {
					Image(systemName: "heart.fill")
						.onTapGesture {
							print("Remove from Favorites")
							Task {
								if await session.favorites?.removeTrack(trackId: track.id) == true {
									session.helpers.offline.asyncSyncFavoriteTracks()
									isFavorite = false
									NotificationCenter.default.post(name: .favoriteTrackChanged, object: nil, userInfo: ["trackId": track.id, "isFavorite": false])
								}
							}
						}
				} else {
					Image(systemName: "heart")
						.onTapGesture {
							print("Add to Favorites")
							Task {
								if await session.favorites?.addTrack(trackId: track.id) == true {
									session.helpers.offline.asyncSyncFavoriteTracks()
									isFavorite = true
									NotificationCenter.default.post(name: .favoriteTrackChanged, object: nil, userInfo: ["trackId": track.id, "isFavorite": true])
								}
							}
						}
				}
				}
			}
		.foregroundColor(track.isUnavailable || playbackInfo.failedTrackIds.contains(track.id) ? .secondary : .primary)
		.onReceive(NotificationCenter.default.publisher(for: .favoriteTrackChanged)) { note in
			guard let changedTrackId = note.userInfo?["trackId"] as? Int, changedTrackId == track.id else { return }
			isFavorite = note.userInfo?["isFavorite"] as? Bool
		}
		.task(id: track.id) {
			isOffline = await track.isOffline(session: session)
			isFavorite = await track.isInFavorites(session: session)
		}
	}
		.lineLimit(1)
		.frame(height: showCover ? 30 : 16) // Values tested "by hand"
	}

	var trackToolTipString: String {
		var s = track.title
		if let version = track.version {
			s += " (\(version))"
		}
		s += " – \(track.artists.formArtistString())"
		return s
	}
}
