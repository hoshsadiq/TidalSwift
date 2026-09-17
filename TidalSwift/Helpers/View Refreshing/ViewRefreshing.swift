//
//  ViewRefreshing.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 26.11.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation
import TidalSwiftLib

extension ViewState {
	func refreshCurrentView() {
		refreshTask?.cancel()
		refreshTask = nil

		switch stack.last?.viewType {
		case .search:
			search()

		case .music:
			music()
		case .explore:
			placeholder(for: .explore)
		case .feed:
			placeholder(for: .feed)
		case .collection:
			placeholder(for: .collection)

		case .newReleases:
			newReleases()
		case .myMixes:
			myMixes()

		case .favoriteArtists:
			favoriteArtists()
		case .favoriteAlbums:
			favoriteAlbums()
		case .favoritePlaylists:
			favoritePlaylists()
		case .favoriteTracks:
			favoriteTracks()
		case .favoriteVideos:
			favoriteVideos()

		case .offlineAlbums:
			offlineAlbums()
		case .offlinePlaylists:
			offlinePlaylists()
		case .offlineTracks:
			offlineTracks()

		case .artist:
			artist()
		case .album:
			album()
		case .playlist:
			playlist()
		case .mix:
			mix()
		case .viewAll:
			// ViewAllPage fetches its own page on appear.
			doNothing()

		case nil:
			doNothing()
		}
	}

	// Only replaces if actually different
	// Also replaces View in History
	func replaceCurrentView(with view: TidalSwiftView) {
		DispatchQueue.main.async { [self] in
			print("replaceCurrentView(): \(stack.last?.viewType.rawValue ?? "nil")")
			if stack.isEmpty {
				print("replaceCurrentView(): ERROR! Stack is empty, but shouldn't at this point. Aborting.")
				return
			}
			if view == stack.last! {
				print("replaceCurrentView(): Fetched View \(view.viewType.rawValue) is exactly the same, so it's not replaced")
				return
			}
			if let stackId = stack.last?.id, stackId == view.id {
				stack[stack.count - 1] = view
				if !history.isEmpty {
					if let historyId = history.last?.id, historyId == view.id {
						history[history.count - 1] = view
					} else {
						addToHistory(view)
					}
				}
			} else {
				print("replaceCurrentView(): Fetched View \(view.viewType.rawValue) is completely different View, so it's not replaced")
			}
		}
	}

	func doNothing() {
		print("ViewState doNothing(): \(stack.last?.viewType.rawValue ?? "nil")")
		refreshTask?.cancel()
		refreshTask = nil
	}

	private func placeholder(for viewType: ViewType) {
		var view = TidalSwiftView(viewType: viewType)
		view.loadingState = .successful
		replaceCurrentView(with: view)
	}
}
