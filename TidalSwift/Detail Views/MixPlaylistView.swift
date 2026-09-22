//
//  MixPlaylistView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct MixPlaylistView: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@State private var isInCollection = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading) {
				if let mix = viewState.stack.last?.mix, let tracks = viewState.stack.last?.tracks {
					HStack {
						MixImage(mix: mix, highResolutionImages: false, session: session)
							.frame(width: 100, height: 100)
							.cornerRadius(CORNERRADIUS)
							.shadow(radius: SHADOWRADIUS, y: SHADOWY)
							#if canImport(AppKit)
							.onTapGesture {
								let controller = ResizableWindowControllerFactory.create(rootView: MixImage(mix: mix, highResolutionImages: true, session: session), width: 640, height: 640)
								controller.window?.title = mix.title
								controller.showWindow(nil)
							}
							#endif

						VStack(alignment: .leading) {
							Text(mix.title)
								.font(.title)
								.lineLimit(2)
							Text(mix.subTitle)
								.foregroundColor(.secondary)
						}
						Spacer(minLength: 0)
						LoadingSpinner()
					}
					.frame(height: 100)
					.padding(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))

					actionRow(mix)

					TrackList(wrappedTracks: tracks.wrapped(), showCover: true, showAlbumTrackNumber: false,
							  showArtist: true, showAlbum: true, playlist: nil,
							  session: session, player: player,
							  source: QueueSource(type: .mix, title: mix.title, id: mix.id))
				}
				Spacer(minLength: 0)
			}
		}
		.task(id: viewState.stack.last?.mix?.id) {
			guard let mix = viewState.stack.last?.mix else { return }
			await viewState.ensureCollectionMixesLoaded()
			isInCollection = viewState.isMixInCollection(mix.id)
		}
		.onReceive(NotificationCenter.default.publisher(for: .collectionMixChanged)) { note in
			guard let mixId = note.userInfo?["mixId"] as? String,
				  mixId == viewState.stack.last?.mix?.id else { return }
			isInCollection = note.userInfo?["isInCollection"] as? Bool ?? viewState.isMixInCollection(mixId)
		}
	}

	/// The screenshot's action row: Play, Shuffle, the collection heart, Share
	/// and the same ⋯ menu the mix cards carry.
	private func actionRow(_ mix: MixesItem) -> some View {
		HStack(spacing: 12) {
			PlayShuffleHeader(onPlay: { play(mix) }, onShuffle: { shuffle(mix) })

			Button {
				viewState.toggleMixInCollection(mix)
			} label: {
				Label(isInCollection ? "Added" : "Add", systemImage: isInCollection ? "heart.fill" : "heart")
					.font(.system(size: 13, weight: .semibold))
					.foregroundColor(.white)
					.padding(.horizontal, 18)
					.frame(height: 36)
					.background(Color.white.opacity(0.15), in: Capsule())
			}
			.buttonStyle(.plain)
			.help(isInCollection ? "Remove from Collection" : "Add to Collection")

			Button {
				Pasteboard.copy(string: "https://www.tidal.com/mix/\(mix.id)")
			} label: {
				Image(systemName: "square.and.arrow.up")
			}
			.buttonStyle(.plain)
			.help("Copy URL")

			Menu {
				MixContextMenu(mix: mix, session: session, player: player)
			} label: {
				Image(systemName: "ellipsis")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.help("More")

			Spacer(minLength: 0)
		}
		.padding(.horizontal, 20)
	}

	private func play(_ mix: MixesItem) {
		guard let tracks = viewState.stack.last?.tracks, !tracks.isEmpty else { return }
		player.playbackInfo.shuffle = false
		player.add(tracks: tracks, .now, source: QueueSource(type: .mix, title: mix.title, id: mix.id))
	}

	private func shuffle(_ mix: MixesItem) {
		guard let tracks = viewState.stack.last?.tracks, !tracks.isEmpty else { return }
		player.playbackInfo.shuffle = true
		player.add(tracks: tracks, .now, source: QueueSource(type: .mix, title: mix.title, id: mix.id))
	}
}
