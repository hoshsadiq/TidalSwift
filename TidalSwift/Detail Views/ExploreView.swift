//
//  ExploreView.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// The Explore hub (`pages/explore`).
///
/// Renders the page's modules in server order: the Featured hero, the
/// Genres / Moods & Activities / Decades pill rows and the untitled icon grid.
struct ExploreView: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 32) {
				Text("Explore")
					.font(.largeTitle)
					.padding(.horizontal)
				content
			}
			.padding(.vertical)
		}
	}

	@ViewBuilder
	private var content: some View {
		if let page = viewState.cache.explorePage {
			modules(for: page)
		} else if viewState.stack.last?.loadingState == .error {
			errorState
		} else {
			FullscreenLoadingSpinner()
		}
	}

	@ViewBuilder
	private func modules(for page: Page) -> some View {
		let modules = page.modules
		if modules.isEmpty {
			ContentUnavailableView {
				Label("Nothing to Show", systemImage: "music.note.list")
			} description: {
				Text("The Explore page didn't return any content.")
			}
			.frame(maxWidth: .infinity, minHeight: 300)
		} else {
			LazyVStack(alignment: .leading, spacing: 32) {
				ForEach(Array(modules.enumerated()), id: \.offset) { _, module in
					moduleView(module)
				}
			}
		}
	}

	/// Dispatches one module to its renderer. Unknown module types are skipped.
	@ViewBuilder
	private func moduleView(_ module: PageModule) -> some View {
		switch module.knownType {
		case .featuredPromotions?, .multipleTopPromotions?:
			FeaturedHero(module: module, session: session, player: player)
		case .pageLinksCloud?:
			PageLinkPills(module: module)
		case .pageLinks?:
			PageLinkGrid(module: module)
		case .textBlock?:
			if let text = module.text {
				TextBlock(text: text)
			}
		default:
			EmptyView()
		}
	}

	private var errorState: some View {
		ContentUnavailableView {
			Label("Couldn't Load Explore", systemImage: "wifi.exclamationmark")
		} description: {
			Text("Check your internet connection, then try again.")
		} actions: {
			Button("Try Again") {
				viewState.explore()
			}
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}
}
