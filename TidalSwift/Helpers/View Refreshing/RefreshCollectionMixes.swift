//
//  RefreshCollectionMixes.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import TidalSwiftLib
import os

extension Notification.Name {
	/// Posted when a mix is added to or removed from the collection.
	///
	/// The mix list lives in `ViewCache`, which isn't observable, so without
	/// this the mix cards on the Collection screen, the mix detail and the v1
	/// page cards would keep stale hearts. `userInfo` carries `mixId` (String)
	/// and `isInCollection` (Bool).
	static let collectionMixChanged = Notification.Name("de.melgu.TidalSwift.collectionMixChanged")
}

extension ViewState {
	private static let mixLogger = Logger(subsystem: "de.melgu.TidalSwift", category: "collection")

	func collectionMixes() {
		var view = TidalSwiftView(viewType: .collectionMixes)
		view.mixes = cache.collectionMixes
		view.loadingState = .loading
		replaceCurrentView(with: view)

		refreshTask?.cancel()
		refreshTask = Task { [self] in
			await refreshCollectionMixes()
		}
	}

	private func refreshCollectionMixes() async {
		var view = TidalSwiftView(viewType: .collectionMixes)
		guard let page = await session.collectionMixes() else {
			guard !Task.isCancelled else { return }
			view.mixes = cache.collectionMixes
			view.loadingState = .error
			replaceCurrentView(with: view)
			return
		}

		guard !Task.isCancelled else { return }
		let mixes = page.items.map(\.data.asMixesItem)

		view.mixes = mixes
		view.loadingState = .successful
		cache.collectionMixes = mixes
		cache.collectionMixesCursor = page.cursor

		replaceCurrentView(with: view)
	}

	/// Whether the mix is in the user's collection, per the shared cache.
	func isMixInCollection(_ mixId: String) -> Bool {
		cache.collectionMixes?.contains { $0.id == mixId } ?? false
	}

	/// Loads the collection-mix list when it isn't cached yet.
	///
	/// Hearts read membership from `cache.collectionMixes`; a screen reached
	/// without visiting Collection ▸ Mixes first (a mix detail, the top-mixes
	/// page) would otherwise show every mix as not added.
	func ensureCollectionMixesLoaded() async {
		guard cache.collectionMixes == nil else { return }
		guard let page = await session.collectionMixes() else { return }
		cache.collectionMixes = page.items.map(\.data.asMixesItem)
		cache.collectionMixesCursor = page.cursor
	}

	/// Replaces the current view's mix list in place.
	///
	/// Optimistic updates can't wait for `replaceCurrentView`'s async
	/// round-trip, so they write the stack entry directly; `stack` is
	/// `@Published`, so the change renders immediately.
	func setCurrentMixes(_ mixes: [MixesItem]) {
		guard !stack.isEmpty else { return }
		stack[stack.count - 1].mixes = mixes
	}

	/// Toggles a mix's collection membership.
	///
	/// Optimistic: the cache is updated and the change announced before the
	/// request, then reverted to the exact previous list (same order) and
	/// announced again when the request fails.
	func toggleMixInCollection(_ mix: MixesItem) {
		Task {
			await ensureCollectionMixesLoaded()
			let previous = cache.collectionMixes ?? []
			let isInCollection = previous.contains { $0.id == mix.id }
			if isInCollection {
				cache.collectionMixes = previous.filter { $0.id != mix.id }
			} else {
				cache.collectionMixes = previous + [mix]
			}
			announceMixCollectionChange(mixId: mix.id, isInCollection: !isInCollection)

			let success = isInCollection
				? await session.removeMixesFromCollection(mixIds: [mix.id])
				: await session.addMixesToCollection(mixIds: [mix.id])
			guard !success else { return }

			cache.collectionMixes = previous
			announceMixCollectionChange(mixId: mix.id, isInCollection: isInCollection)
			Self.mixLogger.error("mix collection toggle failed mixId=\(mix.id, privacy: .public)")
		}
	}

	private func announceMixCollectionChange(mixId: String, isInCollection: Bool) {
		NotificationCenter.default.post(
			name: .collectionMixChanged,
			object: nil,
			userInfo: ["mixId": mixId, "isInCollection": isInCollection]
		)
	}
}
