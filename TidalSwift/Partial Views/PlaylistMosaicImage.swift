//
//  PlaylistMosaicImage.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// The 2×2 cover mosaic TIDAL uses for playlist artwork.
///
/// The hosting card supplies the corner radius and shadow, so the tiles are
/// drawn flat and square here. Tiles are fetched lazily per card and cached in
/// memory only: the ids are cheap to re-fetch and the cache is a scroll-time
/// optimisation, not persisted state, so it deliberately does not touch
/// `ViewCache` (which is written to disk and must stay decodable).
struct PlaylistMosaicImage: View {
	let playlistId: String
	let session: Session
	let size: CGFloat

	@State private var tiles: [String] = []

	/// In-memory, MainActor-isolated cache keyed by playlist id. A static
	/// dictionary is enough because the values are tiny (image ids) and the
	/// whole point is to skip a network round-trip when a card scrolls back
	/// into view.
	@MainActor private static var tileCache: [String: [String]] = [:]

	var body: some View {
		Group {
			if tiles.isEmpty {
				// Same neutral placeholder as the single-cover path, so the
				// card never changes size while the tiles load.
				Rectangle()
					.fill(Color.secondary.opacity(0.15))
			} else {
				mosaic
			}
		}
		.frame(width: size, height: size)
		.task(id: playlistId) {
			await loadTiles()
		}
	}

	/// A grid of equal squares. With fewer than four tiles the available slots
	/// are filled: one tile is full bleed, two sit side by side, three leave
	/// the bottom-right quarter empty.
	private var mosaic: some View {
		GeometryReader { metrics in
			let half = metrics.size.width / 2
			ZStack {
				Color.secondary.opacity(0.15)
				switch tiles.count {
				case 1:
					tile(tiles[0], size: metrics.size.width)
				case 2:
					HStack(spacing: 0) {
						tile(tiles[0], size: half)
						tile(tiles[1], size: half)
					}
					.frame(maxHeight: .infinity, alignment: .top)
				case 3:
					VStack(spacing: 0) {
						HStack(spacing: 0) {
							tile(tiles[0], size: half)
							tile(tiles[1], size: half)
						}
						HStack(spacing: 0) {
							tile(tiles[2], size: half)
							Spacer(minLength: 0)
						}
					}
				default:
					VStack(spacing: 0) {
						HStack(spacing: 0) {
							tile(tiles[0], size: half)
							tile(tiles[1], size: half)
						}
						HStack(spacing: 0) {
							tile(tiles[2], size: half)
							tile(tiles[3], size: half)
						}
					}
				}
			}
		}
	}

	/// One mosaic tile. Corner radius and shadow are disabled because the card
	/// owns both; the tiles are meant to read as a single flat cover.
	private func tile(_ imageId: String, size: CGFloat) -> some View {
		Group {
			if let url = session.imageUrl(imageId: imageId, resolution: 320) {
				ArtworkImage(url: url, size: size, cornerRadius: 0, showsShadow: false)
			} else {
				Color.secondary.opacity(0.15)
					.frame(width: size, height: size)
			}
		}
	}

	private func loadTiles() async {
		if let cached = Self.tileCache[playlistId] {
			tiles = cached
			return
		}
		guard let fetched = await session.playlistArtworkTiles(playlistId: playlistId, limit: 4),
			  !fetched.isEmpty else {
			return
		}
		Self.tileCache[playlistId] = fetched
		tiles = fetched
	}
}
