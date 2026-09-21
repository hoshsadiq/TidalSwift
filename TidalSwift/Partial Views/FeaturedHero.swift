//
//  FeaturedHero.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// A promo item of a `FEATURED_PROMOTIONS` / `MULTIPLE_TOP_PROMOTIONS` module,
/// paired with a stable id so it can drive a `Shelf` carousel.
private struct FeaturedPromotionItem: Identifiable {
	let id: String
	let item: PageItem
}

/// The Explore hero: a horizontal carousel of wide promo cards.
///
/// Renders any `FEATURED_PROMOTIONS` / `MULTIPLE_TOP_PROMOTIONS` module through
/// the shared `Shelf`, so it inherits the paging chevrons and the responsive
/// three-cards-per-viewport sizing. Each card shows the promo artwork (3:2), a
/// green uppercase eyebrow (`header`), a bold title (`shortHeader`) and a
/// secondary description (`shortSubHeader`).
struct FeaturedHero: View {
	let module: PageModule
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState
	@EnvironmentObject var toastCenter: ToastCenter

	private var items: [FeaturedPromotionItem] {
		(module.items ?? []).enumerated().compactMap { index, item in
			guard item.imageId != nil || item.artifactId != nil else { return nil }
			let key = item.artifactId ?? item.header ?? "promo"
			return FeaturedPromotionItem(id: "\(key)-\(index)", item: item)
		}
	}

	var body: some View {
		Shelf(
			title: module.title ?? "",
			onViewAll: nil,
			items: items,
			spacing: 20,
			cardsPerPage: 3
		) { item, cardWidth in
			Button {
				handleTap(item.item)
			} label: {
				FeaturedHeroCard(item: item.item, width: cardWidth, session: session)
			}
			.buttonStyle(.plain)
		}
	}

	/// Routes a promo click by its linked artifact type. Promos never play audio
	/// or video directly: a `VIDEO` promo shows the coming-soon toast.
	private func handleTap(_ item: PageItem) {
		Task {
			switch item.type {
			case "PLAYLIST":
				guard let uuid = item.artifactId else { return }
				if let playlist = await session.playlist(playlistId: uuid) {
					await MainActor.run {
						viewState.push(playlist: playlist)
					}
				}
			case "ALBUM":
				guard let album = item.album else { return }
				await MainActor.run {
					viewState.push(album: album)
				}
			case "ARTIST":
				guard let artist = item.artist else { return }
				await MainActor.run {
					viewState.push(artist: artist)
				}
			case "CATEGORY_PAGES":
				guard let path = item.artifactId else { return }
				await MainActor.run {
					viewState.push(page: PageTarget(path: path, title: item.shortHeader ?? item.header ?? ""))
				}
			case "VIDEO":
				await MainActor.run {
					toastCenter.show(ToastCenter.videoComingSoon)
				}
			default:
				break
			}
		}
	}
}

/// A single promo card: 3:2 artwork with the eyebrow, title and description
/// stacked underneath, left-aligned to the artwork.
private struct FeaturedHeroCard: View {
	let item: PageItem
	let width: CGFloat
	let session: Session

	private var artworkHeight: CGFloat { width * 2 / 3 }

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			artwork
			eyebrow
			title
			description
		}
		.frame(width: width, alignment: .leading)
		.contentShape(Rectangle())
	}

	@ViewBuilder
	private var artwork: some View {
		if let imageId = item.imageId,
		   let url = session.imageUrl(imageId: imageId, resolution: 1100, resolutionY: 800) {
			ArtworkImage(url: url, size: width, height: artworkHeight)
		} else {
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(Color.secondary.opacity(0.15))
				.frame(width: width, height: artworkHeight)
		}
	}

	@ViewBuilder
	private var eyebrow: some View {
		if let header = item.header, !header.isEmpty {
			Text(header)
				.font(.subheadline)
				.fontWeight(.semibold)
				.textCase(.uppercase)
				.tracking(1)
				.foregroundColor(.eyebrowGreen)
				.lineLimit(1)
		}
	}

	@ViewBuilder
	private var title: some View {
		if let shortHeader = item.shortHeader, !shortHeader.isEmpty {
			Text(shortHeader)
				.font(.title3)
				.fontWeight(.semibold)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	@ViewBuilder
	private var description: some View {
		if let shortSubHeader = item.shortSubHeader,
		   !shortSubHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			Text(shortSubHeader)
				.font(.subheadline)
				.foregroundColor(.secondary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
		}
	}
}
