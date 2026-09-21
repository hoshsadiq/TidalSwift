//
//  PageLinkSections.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// A link tile of a `PAGE_LINKS` / `PAGE_LINKS_CLOUD` module, paired with a
/// stable id since `PageItem` itself is not `Identifiable`.
private struct PageLinkItem: Identifiable {
	let id: String
	let item: PageItem
}

/// The renderable tiles of a link module, dropping entries without a target.
private func pageLinkItems(_ module: PageModule) -> [PageLinkItem] {
	let items = module.pagedList?.items ?? module.items ?? []
	return items.enumerated().compactMap { index, item in
		guard let path = item.apiPath, item.title != nil else { return nil }
		return PageLinkItem(id: "\(path)-\(index)", item: item)
	}
}

/// `PAGE_LINKS_CLOUD`: a titled row of text pills that scrolls horizontally.
///
/// The row is a plain `ScrollView` with no paging controls, so the trailing
/// pill is cut by the viewport edge exactly like TIDAL's. "View all" pushes the
/// module's `showMore` page.
struct PageLinkPills: View {
	let module: PageModule

	@EnvironmentObject var viewState: ViewState

	private var items: [PageLinkItem] { pageLinkItems(module) }

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			PageLinkSectionHeader(title: module.title ?? "", onViewAll: viewAllAction)
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 12) {
					ForEach(items) { item in
						Button {
							push(item.item)
						} label: {
							pill(item.item.title ?? "")
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal)
			}
		}
	}

	private var viewAllAction: (() -> Void)? {
		guard let showMore = module.showMore else { return nil }
		return {
			viewState.push(page: PageTarget(path: showMore.apiPath, title: module.title ?? ""))
		}
	}

	private func push(_ item: PageItem) {
		guard let path = item.apiPath else { return }
		viewState.push(page: PageTarget(path: path, title: item.title ?? ""))
	}

	private func pill(_ title: String) -> some View {
		Text(title)
			.font(.headline)
			.lineLimit(1)
			.padding(.horizontal, 18)
			.padding(.vertical, 11)
			.background(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(Color.primary.opacity(0.2))
			)
			.contentShape(Rectangle())
			.help(title)
	}
}

/// `PAGE_LINKS`: a three-column grid of label rows.
///
/// Each row shows an SF-symbol icon when the tile's `icon` maps to one of the
/// hub's five glyphs, otherwise just the label. Every row pushes its tile's
/// page via `apiPath`.
struct PageLinkGrid: View {
	let module: PageModule

	@EnvironmentObject var viewState: ViewState

	private var items: [PageLinkItem] { pageLinkItems(module) }
	private let columns = Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3)

	var body: some View {
		LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
			ForEach(items) { item in
				Button {
					push(item.item)
				} label: {
					row(item.item)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 32)
	}

	private func push(_ item: PageItem) {
		guard let path = item.apiPath else { return }
		viewState.push(page: PageTarget(path: path, title: item.title ?? ""))
	}

	private func row(_ item: PageItem) -> some View {
		HStack(spacing: 10) {
			if let symbol = iconSymbol(for: item.icon) {
				Image(systemName: symbol)
					.font(.body)
					.frame(width: 22)
			}
			Text(item.title ?? "")
				.font(.body)
				.lineLimit(1)
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.vertical, 8)
		.contentShape(Rectangle())
	}

	/// Maps the hub's link icons to SF Symbols. TIDAL's custom genre/mood icon
	/// names (e.g. `hiphop`) have no symbol, so those tiles render label-only.
	private func iconSymbol(for icon: String?) -> String? {
		switch icon {
		case "new":
			return "calendar"
		case "top":
			return "trophy"
		case "videos":
			return "play.rectangle"
		case "hires":
			return "waveform"
		case "clean_content":
			return "e.square"
		default:
			return nil
		}
	}
}

/// The heading shared by the link sections: a server title with an optional
/// "View all" action.
private struct PageLinkSectionHeader: View {
	let title: String
	let onViewAll: (() -> Void)?

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Text(title)
				.font(.title)
			Spacer(minLength: 8)
			if let onViewAll {
				Button("View all", action: onViewAll)
					.buttonStyle(.plain)
					.font(.body)
					.foregroundColor(.secondary)
			}
		}
		.padding(.horizontal)
	}
}
