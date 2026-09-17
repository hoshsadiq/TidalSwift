//
//  Shelf.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI

/// Header for a horizontal shelf.
///
/// Shows a server-supplied title, an optional subtitle, a "View all" action and
/// chevron buttons that page the carousel. All actions are optional closures so
/// the header can be used standalone or driven by `Shelf`.
struct ShelfHeader: View {
	let title: String
	var subtitle: String?
	var onViewAll: (() -> Void)?
	var onScrollBackward: (() -> Void)?
	var onScrollForward: (() -> Void)?
	var canScrollBackward: Bool = true
	var canScrollForward: Bool = true
	/// Whether the paging chevrons are rendered at all. Defaults to `false` so a
	/// header used standalone (or for an empty shelf) does not show controls
	/// that cannot do anything.
	var showsScrollButtons: Bool = false

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.title)
				if let subtitle, !subtitle.isEmpty {
					Text(subtitle)
						.font(.subheadline)
						.foregroundColor(.secondary)
				}
			}
			Spacer(minLength: 8)
			if let onViewAll {
				Button("View all", action: onViewAll)
					.buttonStyle(.link)
			}
			if showsScrollButtons {
				HStack(spacing: 4) {
					Button {
						onScrollBackward?()
					} label: {
						Image(systemName: "chevron.left")
					}
					.disabled(!canScrollBackward || onScrollBackward == nil)
					Button {
						onScrollForward?()
					} label: {
						Image(systemName: "chevron.right")
					}
					.disabled(!canScrollForward || onScrollForward == nil)
				}
				.buttonStyle(.borderless)
			}
		}
		.padding(.horizontal)
	}
}

/// A horizontal carousel of cards with a `ShelfHeader`.
///
/// Data-agnostic: the caller supplies the items and a card builder, so the same
/// component renders albums, playlists, tracks, mixes, etc. The chevrons page
/// the row by one page using a `ScrollViewReader`. Whether the row can scroll is
/// derived from the card footprint (a `LazyHStack` inside a horizontal
/// `ScrollView` reports the viewport width, not the overflowing content width),
/// and manual scrolling resyncs the paging index through `scrollPosition(id:)`.
///
/// By default the card footprint is the fixed `cardWidth`. Setting
/// `cardsPerPage` switches to a responsive mode where the footprint is derived
/// from the measured viewport so exactly that many cards fit, growing and
/// shrinking with the window.
struct Shelf<Item: Identifiable, Content: View>: View {
	let title: String
	var subtitle: String?
	var onViewAll: (() -> Void)?
	let items: [Item]
	/// Footprint of a single card including its own padding. Matches the
	/// existing grid items (160pt artwork + 5pt padding on each side). Used
	/// as-is unless `cardsPerPage` opts into responsive sizing.
	var cardWidth: CGFloat = 170
	/// Gap between cards, matching the default `LazyHStack` spacing used by the
	/// existing horizontal shelves in `SearchView`.
	var spacing: CGFloat = 8
	/// When set, the shelf fits exactly this many cards into the measured
	/// viewport, deriving the card footprint from the available width instead of
	/// using the fixed `cardWidth`. Used by the Music tab so its shelves stay at
	/// four cards per row as the window resizes.
	var cardsPerPage: Int?
	/// The card builder. Receives the item and the resolved card footprint width
	/// (including the card's own padding), so callers can size their artwork to
	/// the available space. In responsive mode this changes as the window
	/// resizes; otherwise it is the fixed `cardWidth`.
	@ViewBuilder var content: (Item, CGFloat) -> Content

	@State private var leadingID: Item.ID?
	/// Authoritative paging index. Kept in sync with manual scrolling through
	/// `leadingID`, and advanced directly by the chevrons so paging never depends
	/// on the scroll-position binding reporting programmatic scrolls.
	@State private var pageIndex: Int = 0
	@State private var viewportWidth: CGFloat = 0

	/// The card footprint actually used for layout. In responsive mode this is
	/// derived from the measured viewport so exactly `cardsPerPage` cards fit;
	/// before the first measurement (or without `cardsPerPage`) it falls back to
	/// the fixed `cardWidth` so nothing renders at zero size.
	private var resolvedCardWidth: CGFloat {
		guard let cardsPerPage, cardsPerPage > 0, viewportWidth > 0 else { return cardWidth }
		let available = viewportWidth - 20 - CGFloat(cardsPerPage - 1) * spacing
		return max(1, available / CGFloat(cardsPerPage))
	}

	private var slotWidth: CGFloat { resolvedCardWidth + spacing }

	private var pageSize: Int {
		if let cardsPerPage, cardsPerPage > 0 { return cardsPerPage }
		guard viewportWidth > 0, slotWidth > 0 else { return 1 }
		return max(1, Int(viewportWidth / slotWidth))
	}

	/// The row can scroll when the cards (plus the `LazyHStack`'s 10pt horizontal
	/// padding on each side) are wider than the viewport. Computed from the card
	/// footprint instead of a measured content width: a `LazyHStack` inside a
	/// horizontal `ScrollView` reports the viewport width, not the content width.
	/// In responsive mode the footprint is derived to fit exactly `cardsPerPage`,
	/// so the row overflows precisely when there are more items than that.
	private var overflows: Bool {
		if let cardsPerPage, cardsPerPage > 0 {
			return items.count > cardsPerPage
		}
		return CGFloat(items.count) * slotWidth + 20 > viewportWidth + 1
	}

	/// Highest leading index from which a full page is still ahead.
	private var lastPageStart: Int {
		max(0, items.count - pageSize)
	}

	private var canScrollBackward: Bool { overflows && pageIndex > 0 }
	private var canScrollForward: Bool { overflows && pageIndex < lastPageStart }

	var body: some View {
		ScrollViewReader { proxy in
			VStack(alignment: .leading, spacing: 0) {
				ShelfHeader(
					title: title,
					subtitle: subtitle,
					onViewAll: onViewAll,
					onScrollBackward: { scroll(proxy, by: -pageSize) },
					onScrollForward: { scroll(proxy, by: pageSize) },
					canScrollBackward: canScrollBackward,
					canScrollForward: canScrollForward,
					showsScrollButtons: overflows
				)
				ScrollView(.horizontal, showsIndicators: false) {
					LazyHStack(alignment: .top, spacing: spacing) {
						ForEach(items) { item in
							content(item, resolvedCardWidth)
								.id(item.id)
						}
					}
					.padding(10)
					.scrollTargetLayout()
				}
				.scrollPosition(id: $leadingID)
				.scrollTargetBehavior(.viewAligned)
				.onChange(of: leadingID) { _, newValue in
					// Manual scrolling: resync our index. Programmatic scrolls may
					// not update the binding, which is why the chevrons advance
					// `pageIndex` themselves.
					guard let newValue, let index = items.firstIndex(where: { $0.id == newValue }) else { return }
					pageIndex = index
				}
				.onChange(of: items.count) { _, _ in
					pageIndex = min(pageIndex, lastPageStart)
				}
				.background(
					GeometryReader { geometry in
						Color.clear
							.onAppear { viewportWidth = geometry.size.width }
							.onChange(of: geometry.size.width) { _, newWidth in
								viewportWidth = newWidth
							}
					}
				)
			}
		}
	}

	private func scroll(_ proxy: ScrollViewProxy, by offset: Int) {
		guard !items.isEmpty else { return }
		let target = min(max(pageIndex + offset, 0), lastPageStart)
		pageIndex = target
		withAnimation {
			proxy.scrollTo(items[target].id, anchor: .leading)
		}
	}
}

#Preview {
	Shelf(
		title: "Made For You",
		subtitle: "Picked for your taste",
		onViewAll: {},
		items: PreviewShelfItem.samples,
		cardsPerPage: 4,
		content: { item, cardWidth in
			VStack {
				RoundedRectangle(cornerRadius: CORNERRADIUS)
					.fill(item.color.gradient)
					.frame(width: cardWidth - 10, height: cardWidth - 10)
				Text(item.title)
					.lineLimit(1)
					.frame(width: cardWidth - 10)
			}
			.padding(5)
		}
	)
	.frame(width: 700)
}

private struct PreviewShelfItem: Identifiable {
	let id: Int
	let title: String
	let color: Color

	static let samples: [PreviewShelfItem] = (1...8).map {
		PreviewShelfItem(id: $0, title: "Card \($0)", color: .blue)
	}
}
