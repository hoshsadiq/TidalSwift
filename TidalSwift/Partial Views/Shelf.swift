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
	var subtitle: String? = nil
	var onViewAll: (() -> Void)? = nil
	var onScrollBackward: (() -> Void)? = nil
	var onScrollForward: (() -> Void)? = nil
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
/// the row by one viewport width using a `ScrollViewReader`, while a
/// `GeometryReader`/`PreferenceKey` pair measures the real scroll offset and
/// content width. That measurement drives both the chevrons' visibility (only
/// shown when the row overflows) and their enabled state, which tracks manual
/// scrolling live.
struct Shelf<Item: Identifiable, Content: View>: View {
	let title: String
	var subtitle: String? = nil
	var onViewAll: (() -> Void)? = nil
	let items: [Item]
	/// Footprint of a single card including its own padding. Matches the
	/// existing grid items (160pt artwork + 5pt padding on each side).
	var cardWidth: CGFloat = 170
	/// Gap between cards, matching the default `LazyHStack` spacing used by the
	/// existing horizontal shelves in `SearchView`.
	var spacing: CGFloat = 8
	@ViewBuilder var content: (Item) -> Content

	@State private var scrollOffset: CGFloat = 0
	@State private var contentWidth: CGFloat = 0
	@State private var viewportWidth: CGFloat = 0
	/// Unique per shelf so multiple shelves on screen do not share a coordinate
	/// space.
	@State private var coordinateSpaceName = UUID()

	private var slotWidth: CGFloat { cardWidth + spacing }

	private var pageSize: Int {
		guard viewportWidth > 0, slotWidth > 0 else { return 1 }
		return max(1, Int(viewportWidth / slotWidth))
	}

	/// Whether the content is wider than the viewport, i.e. the row can scroll.
	private var overflows: Bool {
		contentWidth > viewportWidth + 1
	}

	/// Index of the card at the leading edge, derived from the real scroll
	/// offset rather than a `scrollPosition` binding.
	private var currentIndex: Int {
		guard !items.isEmpty, slotWidth > 0 else { return 0 }
		let index = Int((scrollOffset / slotWidth).rounded())
		return min(max(index, 0), items.count - 1)
	}

	private var canScrollBackward: Bool {
		overflows && scrollOffset > 1
	}

	private var canScrollForward: Bool {
		overflows && scrollOffset + viewportWidth < contentWidth - 1
	}

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
							content(item)
								.id(item.id)
						}
					}
					.padding(10)
					.scrollTargetLayout()
					.background(
						GeometryReader { geometry in
							let frame = geometry.frame(in: .named(coordinateSpaceName))
							Color.clear.preference(
								key: ShelfScrollMetricsKey.self,
								value: ShelfScrollMetrics(
									offset: -frame.minX,
									contentWidth: geometry.size.width
								)
							)
						}
					)
				}
				.coordinateSpace(.named(coordinateSpaceName))
				.scrollTargetBehavior(.viewAligned)
				.onPreferenceChange(ShelfScrollMetricsKey.self) { metrics in
					scrollOffset = metrics.offset
					contentWidth = metrics.contentWidth
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
		let target = min(max(currentIndex + offset, 0), items.count - 1)
		withAnimation {
			proxy.scrollTo(items[target].id, anchor: .leading)
		}
	}
}

/// Scroll metrics reported by a `Shelf`'s content.
private struct ShelfScrollMetrics: Equatable {
	/// Distance scrolled from the leading edge, `0` at the start.
	var offset: CGFloat = 0
	/// Full width of the scrollable content, including its horizontal padding.
	var contentWidth: CGFloat = 0
}

/// Propagates `ShelfScrollMetrics` from the scroll content up to the `Shelf`.
private struct ShelfScrollMetricsKey: PreferenceKey {
	static var defaultValue: ShelfScrollMetrics { ShelfScrollMetrics() }

	static func reduce(value: inout ShelfScrollMetrics, nextValue: () -> ShelfScrollMetrics) {
		value = nextValue()
	}
}

#Preview {
	Shelf(title: "Made For You", subtitle: "Picked for your taste", onViewAll: {}, items: PreviewShelfItem.samples) { item in
		VStack {
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(item.color.gradient)
				.frame(width: 160, height: 160)
			Text(item.title)
				.lineLimit(1)
				.frame(width: 160)
		}
		.padding(5)
	}
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
