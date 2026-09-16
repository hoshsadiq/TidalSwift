//
//  PlayerInfoView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 21.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib
import Sliders

struct PlayerInfoView: View {
	let session: Session
	let player: Player


	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var appModel: TidalSwiftAppModel
	// Disabled until the Now Playing drawer is built.
	// @EnvironmentObject var playbackInfo: PlaybackInfo

	var body: some View {
		VStack {
			GeometryReader { metrics in
				HStack {
					HStack {
						TrackInfoView(player: player, session: session)

						if queueInfo.queue.indices.contains(queueInfo.currentIndex) {
							let track = queueInfo.queue[queueInfo.currentIndex].track
							Button {
								toggleFavorite(track: track)
							} label: {
								Image(systemName: appModel.trackIsFavorite ? "heart.fill" : "heart")
									.foregroundColor(appModel.trackIsFavorite ? .red : .primary)
							}
							.buttonStyle(.plain)
							.help(appModel.trackIsFavorite ? "Remove from Favorites" : "Add to Favorites")

							Menu {
								TrackContextMenu(track: track, session: session, player: player)
							} label: {
								Image(systemName: "ellipsis")
							}
							.menuStyle(.borderlessButton)
							.menuIndicator(.hidden)
							.fixedSize()
							.help("More Actions")
						}

						Spacer()
							.layoutPriority(-1)
					}
					.contentShape(Rectangle())
					// Disabled until the Now Playing drawer is built.
					// .onTapGesture {
					// 	playbackInfo.isNowPlayingExpanded.toggle()
					// }
					.contextMenu {
						if !queueInfo.queue.isEmpty {
							let track = queueInfo.queue[queueInfo.currentIndex].track
							TrackContextMenu(track: track, session: session, player: player)
						}
					}
					.frame(width: metrics.size.width / 2 - 100)

					PlaybackControls(player: player)
						.frame(width: 260)
					Spacer()
					VolumeControl(player: player)
					Spacer()
					DownloadIndicator()
					#if canImport(AppKit)
					Image(systemName: "quote.bubble")
						.help("Lyrics")
						.onTapGesture {
							appModel.showLyricsWindow()
						}
					Image(systemName: "list.dash")
						.help("Queue")
						.foregroundColor(appModel.showQueuePanel ? .accentColor : .primary)
						.onTapGesture {
							withAnimation {
								appModel.showQueuePanel.toggle()
							}
						}
					#endif
					Button {
					} label: {
						Image(systemName: "airplayaudio")
					}
					.buttonStyle(.plain)
					.disabled(true)
					.help("Coming soon")

					Button {
					} label: {
						Image(systemName: "rectangle.on.rectangle")
					}
					.buttonStyle(.plain)
					.disabled(true)
					.help("Coming soon")

					QualityBadge(text: player.currentQualityString(), tint: .orange)
						.help("Current Quality")
				}
			}
			.frame(height: 64)
			.padding([.top, .horizontal])
		}
	}

	private func toggleFavorite(track: Track) {
		let wasFavorite = appModel.trackIsFavorite
		Task {
			guard let favorites = session.favorites else { return }
			let success: Bool
			if wasFavorite {
				success = await favorites.removeTrack(trackId: track.id)
			} else {
				success = await favorites.addTrack(trackId: track.id)
			}
			if success {
				session.helpers.offline.asyncSyncFavoriteTracks()
				appModel.refreshFavoriteState()
				NotificationCenter.default.post(
					name: .favoriteTrackChanged,
					object: nil,
					userInfo: ["trackId": track.id, "isFavorite": !wasFavorite]
				)
			}
		}
	}
}

struct TrackInfoView: View {
	let player: Player
	let session: Session

	@EnvironmentObject var queueInfo: QueueInfo

	var body: some View {
		HStack {
			if queueInfo.queue.indices.contains(queueInfo.currentIndex) {
				let track = queueInfo.queue[queueInfo.currentIndex].track
				HStack {
					if let coverUrlSmall = track.getCoverUrl(session: session, resolution: 320),
					   let coverUrlBig = track.getCoverUrl(session: session, resolution: 1280) {
						AsyncImage(url: coverUrlSmall) { image in
							image.resizable().scaledToFit()
						} placeholder: {
							Rectangle()
						}
						.frame(width: 40, height: 40)
						.cornerRadius(CORNERRADIUS)
						.help("Show cover in new window")
						#if canImport(AppKit)
						.onTapGesture(count: 2) {
							print("Big Cover")
							let title = "\(track.title) – \(track.album.title)"
							let controller = ImageWindowController(
								imageUrl: coverUrlBig,
								title: title
							)
							controller.window?.title = title
							controller.showWindow(nil)
						}
						#endif
						.accessibilityHidden(true)
					} else {
						Rectangle()
							.foregroundColor(.black)
							.frame(width: 40, height: 40)
							.cornerRadius(CORNERRADIUS)
					}

					VStack(alignment: .leading, spacing: 3) {
						HStack {
							Text("\(track.title)")
							if let version = track.version {
								Text(version)
									.foregroundColor(.secondary)
									.padding(.leading, -5)
									.layoutPriority(-1)
							}
						}
						.help(trackToolTipString(for: track))
						Text("\(track.artists.formArtistString()) – \(track.album.title)")
							.foregroundColor(.secondary)
							.help("\(track.artists.formArtistString()) – \(track.album.title)")
						if let source = queueInfo.source {
							HStack(spacing: 3) {
								Image(systemName: source.type.symbolName)
								Text("Playing from \(source.title)")
									.lineLimit(1)
							}
							.font(.caption)
							.foregroundColor(.secondary)
							.help("Playing from \(source.title)")
						}
					}
				}
			} else {
				Spacer()
			}
		}
	}

	func trackToolTipString(for track: Track) -> String {
		var s = track.title
		if let version = track.version {
			s += " (\(version))"
		}
		s += " – \(track.artists.formArtistString())"
		return s
	}
}

extension QueueSource.CollectionType {
	fileprivate var symbolName: String {
		switch self {
		case .playlist:
			return "music.note.list"
		case .album:
			return "square.stack"
		case .artist:
			return "person"
		case .favorite:
			return "heart.fill"
		case .mix:
			return "square.grid.2x2"
		}
	}
}

struct QualityBadge: View {
	let text: String
	let tint: Color

	var body: some View {
		if text.isEmpty {
			EmptyView()
		} else {
			Text(text)
				.font(.system(size: 9, weight: .semibold))
				.foregroundColor(tint)
				.padding(.horizontal, 5)
				.padding(.vertical, 1)
				.background(
					RoundedRectangle(cornerRadius: CORNERRADIUS, style: .continuous)
						.fill(tint.opacity(0.15))
				)
				.overlay(
					RoundedRectangle(cornerRadius: CORNERRADIUS, style: .continuous)
						.stroke(tint.opacity(0.35), lineWidth: 0.5)
				)
		}
	}
}

struct PlaybackControls: View {
	let player: Player

	@EnvironmentObject var playbackInfo: PlaybackInfo

	var body: some View {
		VStack(spacing: 6) {
			HStack {
				Spacer()
				Group {
					Image(systemName: "shuffle")
						.foregroundStyle(playbackInfo.shuffle ? Color.controlAccentColor : Color.secondary)
				}
				.help("Shuffle")
				.onTapGesture {
					playbackInfo.shuffle.toggle()
				}
				Image(systemName: "backward.fill")
					.onTapGesture {
						player.previous()
					}
				if playbackInfo.playing {
					Image(systemName: "pause.fill")
						.onTapGesture {
							player.pause()
						}
				} else {
					Image(systemName: "play.fill")
						.onTapGesture {
							player.play()
						}
				}
				Image(systemName: "forward.fill")
					.onTapGesture {
						player.next()
					}
				Group {
					Image(systemName: playbackInfo.repeatState == .single ? "repeat.1" : "repeat")
						.foregroundStyle(
							playbackInfo.repeatState == .off ? Color.secondary : Color.controlAccentColor
						)
				}
				.help("Repeat")
				.onTapGesture {
					player.playbackInfo.repeatState = player.playbackInfo.repeatState.next()
					print("Repeat: \(player.playbackInfo.repeatState)")
				}
				Spacer()
			}
			ProgressBar(player: player)
		}
	}
}

struct ProgressBar: View {
	let player: Player

	@EnvironmentObject var playbackInfo: PlaybackInfo
	@Environment(\.colorScheme) var colorScheme: ColorScheme

	var body: some View {
		ValueSlider(value: $playbackInfo.fraction) { down in
			if down { // Only apply while scrubbing, not when releasing
				player.seek(to: Double(playbackInfo.fraction))
			}
		}
		.valueSliderStyle(
			HorizontalValueSliderStyle(track: HorizontalValueTrack(view:
																	Rectangle()
																	.foregroundColor(.playbackProgressBarForeground(for: colorScheme))
																	.frame(height: 8),
																   mask: Rectangle()
			)
			.background(Color.playbackProgressBarBackground(for: colorScheme))
			.frame(height: 8)
			.cornerRadius(4)
			.help((playbackInfo.playbackTimeInfo)),
			thumb: EmptyView(),
			thumbSize: .zero,
			options: .interactiveTrack)
		)
		.frame(height: 8)
	}
}

struct VolumeControl: View {
	let player: Player

	@EnvironmentObject var playbackInfo: PlaybackInfo

	var body: some View {
		HStack {
			speakerSymbol
				.frame(width: 20, alignment: .leading)
				.onTapGesture {
					player.toggleMute()
				}
			ValueSlider(value: $playbackInfo.volume, in: 0.0...1.0)
				.valueSliderStyle(
					HorizontalValueSliderStyle(track:
												HorizontalValueTrack(view:
													Rectangle()
														.foregroundColor(.secondary)
														.frame(height: 4)
												)
												.background(Color.secondary)
												.frame(height: 4)
												.cornerRadius(3),
											   thumbSize: CGSize(width: 15, height: 15),
											   options: .interactiveTrack)
				)
				.frame(width: 80, height: 30)
				.layoutPriority(1)
		}
	}

	@ViewBuilder
	var speakerSymbol: some View {
		if playbackInfo.volume > 0.66 {
			Image(systemName: "speaker.3.fill")
		} else if playbackInfo.volume > 0.33 {
			Image(systemName: "speaker.2.fill")
		} else if playbackInfo.volume > 0 {
			Image(systemName: "speaker.1.fill")
		} else {
			Image(systemName: "speaker.fill") // or 􀊣
		}
	}
}
