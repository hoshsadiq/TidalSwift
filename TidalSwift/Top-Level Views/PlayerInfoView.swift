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
#if canImport(AppKit)
import AppKit
#endif

struct PlayerInfoView: View {
	let session: Session
	let player: Player


	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var appModel: TidalSwiftAppModel
	@EnvironmentObject var playbackInfo: PlaybackInfo

	var body: some View {
		VStack {
			GeometryReader { metrics in
				HStack {
					HStack {
						TrackInfoView(player: player, session: session)

					if queueInfo.queue.indices.contains(queueInfo.currentIndex) {
						let track = queueInfo.queue[queueInfo.currentIndex].track
						FavoriteButton(track: track, session: session, hitPadding: 6)

						Menu {
								TrackContextMenu(track: track, session: session, player: player)
							} label: {
								Image(systemName: "ellipsis")
									.padding(6)
									.contentShape(Rectangle())
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
						.padding(6)
						.contentShape(Rectangle())
						.help("Lyrics")
						.onTapGesture {
							withAnimation(.easeInOut(duration: 0.3)) {
								playbackInfo.isNowPlayingExpanded = true
								playbackInfo.activePanel = .lyrics
							}
						}
					Image(systemName: "list.dash")
						.padding(6)
						.contentShape(Rectangle())
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

					#if canImport(AppKit)
					Button {
						appModel.toggleMiniplayer()
					} label: {
						Image(systemName: "rectangle.on.rectangle")
							.foregroundColor(appModel.isMiniplayerOpen ? .accentColor : .primary)
					}
					.buttonStyle(.plain)
					.help(appModel.isMiniplayerOpen ? "Close Miniplayer" : "Open Miniplayer")
					.accessibilityLabel("Miniplayer")
					#endif

					QualityBadge(text: player.currentQualityString(), tint: .orange)
						.help("Current Quality")
				}
			}
			.frame(height: 64)
			.padding([.top, .horizontal])
		}
		// While the drawer is expanded the bar adopts the drawer's ambient
		// colour — the same `PlaybackInfo.ambientColor` that `NowPlayingAmbientLayer`
		// derives and fills behind the drawer — so the two read as one surface.
		// Collapsed, it returns to the window background.
		.background(playbackInfo.isNowPlayingExpanded ? playbackInfo.ambientColor : Color(nsColor: .windowBackgroundColor))
		.contentShape(Rectangle())
		.onTapGesture {
			playbackInfo.isNowPlayingExpanded.toggle()
		}
	}
}

/// Heart toggle for the current track, shared by the player bar and miniplayer.
///
/// State comes from `TidalSwiftAppModel.trackIsFavorite` (refreshed on queue /
/// index changes) so every host stays in sync without owning favorite state.
struct FavoriteButton: View {
	let track: Track
	let session: Session
	/// Extra hit-target padding around the glyph. The player bar sits inside a
	/// tap-to-expand container, so it needs a larger target than the miniplayer.
	var hitPadding: CGFloat = 0

	@EnvironmentObject var appModel: TidalSwiftAppModel

	var body: some View {
		Button {
			toggleFavorite()
		} label: {
			Image(systemName: appModel.trackIsFavorite ? "heart.fill" : "heart")
				.foregroundColor(appModel.trackIsFavorite ? .red : .primary)
				.padding(hitPadding)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(appModel.trackIsFavorite ? "Remove from Favorites" : "Add to Favorites")
		.accessibilityLabel(appModel.trackIsFavorite ? "Remove from Favorites" : "Add to Favorites")
	}

	private func toggleFavorite() {
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
						.padding(6)
						.contentShape(Rectangle())
				}
				.help("Shuffle")
				.onTapGesture {
					playbackInfo.shuffle.toggle()
				}
				Image(systemName: "backward.fill")
					.padding(6)
					.contentShape(Rectangle())
					.onTapGesture {
						player.previous()
					}
				if playbackInfo.playing {
					Image(systemName: "pause.fill")
						.padding(6)
						.contentShape(Rectangle())
						.onTapGesture {
							player.pause()
						}
				} else {
					Image(systemName: "play.fill")
						.padding(6)
						.contentShape(Rectangle())
						.onTapGesture {
							player.play()
						}
				}
				Image(systemName: "forward.fill")
					.padding(6)
					.contentShape(Rectangle())
					.onTapGesture {
						player.next()
					}
				Group {
					Image(systemName: playbackInfo.repeatState == .single ? "repeat.1" : "repeat")
						.foregroundStyle(
							playbackInfo.repeatState == .off ? Color.secondary : Color.controlAccentColor
						)
						.padding(6)
						.contentShape(Rectangle())
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
