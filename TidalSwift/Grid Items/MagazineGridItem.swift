//
//  MagazineGridItem.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib
import os

/// A TIDAL magazine card for the horizontal shelves (Staff Picks "Editorial
/// Radar" / "Tidal Magazine", Uploads "Featured").
///
/// Unlike the square album/playlist cards, magazine artwork is landscape
/// (550×400 ≈ 1.375:1). The card keeps the same footprint width as its
/// neighbours so it sits correctly in the shelf, and routes its click by the
/// payload's content kind.
struct MagazineGridItem: View {
	let magazine: HomeFeedMagazine
	let session: Session
	let player: Player
	var artworkSize: CGFloat = 160

	@EnvironmentObject var viewState: ViewState
	@Environment(\.openURL) private var openURL

	/// TIDAL's magazine artwork is 550×400.
	private static let artworkAspectRatio: CGFloat = 550.0 / 400.0

	private var artworkHeight: CGFloat { artworkSize / Self.artworkAspectRatio }

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			artwork
			if let header = magazine.header, !header.isEmpty {
				Text(header)
					.font(.caption2)
					.fontWeight(.semibold)
					.foregroundColor(.secondary)
					.textCase(.uppercase)
					.lineLimit(1)
					.frame(width: artworkSize, alignment: .leading)
			}
			Text(magazine.shortHeader ?? "")
				.fontWeight(.semibold)
				.lineLimit(2)
				.frame(width: artworkSize, alignment: .leading)
			if let subHeader = magazine.shortSubHeader, !subHeader.trimmingCharacters(in: .whitespaces).isEmpty {
				Text(subHeader)
					.fontWeight(.light)
					.foregroundColor(.secondary)
					.lineLimit(2)
					.frame(width: artworkSize, alignment: .leading)
			}
		}
		.padding(5)
		.contentShape(Rectangle())
		.help(toolTipString)
		.onAppear {
			Logger(subsystem: "de.melgu.TidalSwift", category: "magazine")
				.info("MAGAZINE CARD RENDERED id=\(magazine.id, privacy: .public) kind=\(magazine.type, privacy: .public) header=\(magazine.header ?? "", privacy: .public)")
		}
		.onTapGesture {
			open()
		}
	}

	@ViewBuilder
	private var artwork: some View {
		if let url = magazine.imageURL {
			ArtworkImage(url: url, size: artworkSize, height: artworkHeight)
		} else {
			ZStack {
				Rectangle()
					.foregroundColor(Color.secondary.opacity(0.15))
				Image(systemName: "doc.text.image")
					.font(.system(size: artworkSize * 0.2))
					.foregroundColor(.secondary)
			}
			.frame(width: artworkSize, height: artworkHeight)
			.cornerRadius(CORNERRADIUS)
			.shadow(radius: SHADOWRADIUS, y: SHADOWY)
		}
	}

	private var toolTipString: String {
		[magazine.header, magazine.shortHeader, magazine.shortSubHeader]
			.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
			.joined(separator: " – ")
	}

	/// Routes the click by the payload's content kind. Album and playlist
	/// flavours open in-app; article and curated-page flavours open in the
	/// browser.
	private func open() {
		switch magazine.type {
		case "ALBUM":
			guard let albumId = Int(magazine.artifactId) else { return }
			Task {
				if let album = await session.album(albumId: albumId) {
					viewState.push(album: album)
				}
			}
		case "PLAYLIST":
			Task {
				if let playlist = await session.playlist(playlistId: magazine.artifactId) {
					viewState.push(playlist: playlist)
				}
			}
		case "EXTURL":
			if let url = URL(string: magazine.artifactId) {
				openURL(url)
			}
		case "CATEGORY_PAGES":
			// No in-app curated-page viewer yet, so open the TIDAL web page.
			// Follow-up: render `pages/...` in-app instead of leaving the app.
			if let url = URL(string: "https://tidal.com/\(magazine.artifactId)") {
				openURL(url)
			}
		default:
			break
		}
	}
}
