//
//  MixGridItem.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

struct MixGridItem: View {
	let mix: MixesItem
	let session: Session
	let player: Player
	var artworkSize: CGFloat = 160
	/// When set, this single artwork replaces the mix's own collage.
	var artworkURL: URL?
	/// Opt-in heart overlay, top-trailing on the artwork. Off by default so the
	/// Music tab's mix shelves are unchanged.
	var showsHeart: Bool = false
	/// Whether the heart reads as added. Only meaningful when `showsHeart`.
	var heartIsOn: Bool = false
	/// Toggle handler for the heart. When nil the heart is shown but inert.
	var onToggleHeart: (() -> Void)?
	/// Opt-in title/subtitle drawn over the artwork in the API-provided colours.
	/// Off by default; the lines below the artwork are always shown.
	var overlaysTitle: Bool = false
	/// Colour for the overlaid title, from the mix's `titleTextInfo.color`.
	/// Falls back to white when nil.
	var overlayTitleColor: Color?
	/// Colour for the overlaid subtitle, from the mix's `subTitleTextInfo.color`.
	/// Falls back to white when nil.
	var overlaySubtitleColor: Color?

	@EnvironmentObject var viewState: ViewState

	var body: some View {
		VStack {
			ZStack(alignment: .bottomLeading) {
				artwork
				if overlaysTitle {
					overlayText
				}
			}
			.overlay(alignment: .topTrailing) {
				if showsHeart {
					heartButton
				}
			}

			Text(mix.title)
				.frame(width: artworkSize)
			Text(mix.subTitle)
				.fontWeight(.light)
				.foregroundColor(Color.secondary)
				.lineLimit(1)
				.frame(width: artworkSize)
		}
		.padding(5)
	.onTapGesture(count: 2) {
		print("Second Click. \(mix.title)")
		Task {
			if let tracks = await session.mixPlaylistTracks(mixId: mix.id) {
				player.add(tracks: tracks, .now, source: QueueSource(type: .mix, title: mix.title, id: mix.id))
			}
		}
	}
		.onTapGesture(count: 1) {
			print("First Click. \(mix.title)")
			viewState.push(mix: mix)
		}
		.contextMenu {
			MixContextMenu(mix: mix, session: session, player: player)
		}
	}

	/// The mix's own collage, or the caller-supplied single artwork. Unchanged
	/// from the original card so the Music tab's shelves render identically.
	@ViewBuilder
	private var artwork: some View {
		if let artworkURL {
			ArtworkImage(url: artworkURL, size: artworkSize)
		} else {
			MixImage(mix: mix, highResolutionImages: false, session: session)
				.frame(width: artworkSize, height: artworkSize)
				.cornerRadius(CORNERRADIUS)
				.shadow(radius: SHADOWRADIUS, y: SHADOWY)
				.accessibilityHidden(true)
		}
	}

	/// Title and subtitle drawn over the artwork's bottom-leading corner in the
	/// API-provided colours, sized relative to the artwork so the card scales.
	private var overlayText: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(mix.title)
				.font(.system(size: artworkSize * 0.12, weight: .bold))
				.foregroundColor(overlayTitleColor ?? .white)
				.lineLimit(2)
			Text(mix.subTitle)
				.font(.system(size: artworkSize * 0.09))
				.foregroundColor(overlaySubtitleColor ?? .white)
				.lineLimit(1)
		}
		.padding(artworkSize * 0.06)
		.frame(width: artworkSize, alignment: .leading)
	}

	/// A `Button` rather than a bare tap gesture so the heart consumes its own
	/// tap: the card's single/double-click gestures sit on the enclosing
	/// `VStack`, and the innermost control wins, so a heart tap only toggles.
	private var heartButton: some View {
		Button {
			onToggleHeart?()
		} label: {
			Image(systemName: heartIsOn ? "heart.fill" : "heart")
				.font(.system(size: 16, weight: .semibold))
				.foregroundColor(.white)
				.shadow(radius: 2)
				.frame(width: 28, height: 28)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.padding(6)
		.disabled(onToggleHeart == nil)
	}
}

struct MixImage: View {
	let mix: MixesItem
	let highResolutionImages: Bool
	let session: Session

	let lowResolution: Int = 160
	let highResolution: Int = 480

	@State var scrollImages = false

	var body: some View {
		GeometryReader { metrics in
			if let graphic = mix.graphic, graphic.images.count >= 5 {
				ZStack {
					VStack {
						HStack {
							Text(mix.title)
								.font(.system(size: metrics.size.width * 0.1))
								.bold()
								.foregroundColor(Color(hex: graphic.images[0].vibrantColor) ?? Color.gray)
								.padding(metrics.size.width * 0.1)
							Spacer()
						}
						Spacer()
					}

					// Animated Images
					VStack {
						HStack {
							// 4
							if let imageUrl = graphic.images[4].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}

							// 0 1
							if let imageUrl = graphic.images[0].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[1].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}

							// 2 3 4
							if let imageUrl = graphic.images[2].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[3].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[4].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}

							// 0 1
							if let imageUrl = graphic.images[0].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[1].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}

							Spacer()
								.frame(width: metrics.size.width * 0.2)
						}
						HStack {
							Spacer()
								.frame(width: metrics.size.width * 0.2)

							// 2 3 4
							if let imageUrl = graphic.images[2].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(.trailing, metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[3].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[4].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}

							// 0 1
							if let imageUrl = graphic.images[0].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[1].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}

							// 2 3 4
							if let imageUrl = graphic.images[2].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[3].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
							if let imageUrl = graphic.images[4].getImageUrl(session: session, resolution: highResolutionImages ? highResolution : lowResolution) {
								collageTile(imageUrl, width: metrics.size.width)
									.padding(metrics.size.width * 0.01)
							}
						}
					}
					.padding(metrics.size.width * 0.06)
					.offset(x: scrollImages ? metrics.size.width * -2.7 : metrics.size.width * -0.35)
					.rotationEffect(Angle(degrees: -12))
					.position(CGPoint(x: metrics.size.width * 2, y: metrics.size.width * 0.4))
					.scaleEffect(1)
					.onAppear {
						withAnimation(Animation.linear(duration: 10).repeatForever(autoreverses: false)) {
							scrollImages.toggle()
						}
					}
				}
				.contentShape(Rectangle())
				.clipped()
				.overlay(
					RoundedRectangle(cornerRadius: CORNERRADIUS)
						.stroke(Color(hex: graphic.images[0].vibrantColor) ?? Color.gray, lineWidth: metrics.size.width * 0.1)
				)
				.background((Color(hex: graphic.images[0].vibrantColor) ?? Color.gray).colorMultiply(Color.gray))
			} else if let imageUrl = mix.images?.medium?.url ?? mix.images?.large?.url ?? mix.images?.small?.url {
				// Page mixes ship finished square artwork in `images` rather than a
				// client-assembled `graphic` collage.
				ArtworkImage(url: imageUrl, size: metrics.size.width, cornerRadius: 0, showsShadow: false)
			} else {
				// No cover art: fill the same footprint as the real artwork with a
				// neutral placeholder so the card keeps its size and alignment.
				ZStack {
					Rectangle()
						.foregroundColor(Color.secondary.opacity(0.15))
					Image(systemName: "music.note")
						.font(.system(size: metrics.size.width * 0.3))
						.foregroundColor(.secondary)
				}
			}
		}
	}

	/// One collage tile. The tiles never had a shadow or corner radius of their
	/// own (the enclosing `MixGridItem` supplies both), so both are disabled to
	/// keep the exact previous geometry.
	private func collageTile(_ imageUrl: URL, width: CGFloat) -> some View {
		ArtworkImage(url: imageUrl, size: width * 0.4, cornerRadius: 0, showsShadow: false)
	}
}
