//
//  Collection.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

// MARK: - Collection mixes

extension Session {
	/// Fetches one page of the user's collection mixes
	/// (`/v2/my-collection/mixes`).
	///
	/// The list is cursor-paged: pass the previous page's `cursor` to fetch the
	/// next one. Returns `nil` on any failure.
	public func collectionMixes(cursor: String? = nil) async -> CollectionMixPage? {
		var parameters = sessionParameters
		parameters["limit"] = "50"
		if let cursor {
			parameters["cursor"] = cursor
		}
		guard let url = Self.v2URL(path: "my-collection/mixes") else { return nil }
		do {
			let response: CollectionMixPage = try await v2Get(url: url, parameters: parameters)
			return response
		} catch {
			return nil
		}
	}

	/// Fetches the tracks of a mix (`/v1/mixes/{id}/items`).
	///
	/// Unlike the v2 collection list, this v1 route returns plain `Track`
	/// objects in the shared `Tracks` envelope. Returns `nil` on any failure.
	public func collectionMixItems(mixId: String) async -> [Track]? {
		let url = URL(string: "\(AuthInformation.APILocation)/mixes/\(mixId)/items")!
		do {
			let response: Tracks = try await get(url: url, parameters: sessionParameters)
			return response.items
		} catch {
			return nil
		}
	}

	/// Adds mixes to the user's collection (`/v2/favorites/mixes/add`).
	///
	/// Returns `true` when the request succeeded. The success body shape is
	/// unverified (the route was only proven with a failing id), so a 200 whose
	/// body doesn't decode still counts as success; when it does decode, the
	/// change confirms whether the mixes were actually added.
	public func addMixesToCollection(mixIds: [String]) async -> Bool {
		await changeMixes(mixIds: mixIds, removing: false)
	}

	/// Removes mixes from the user's collection (`/v2/favorites/mixes/remove`).
	///
	/// Returns `true` when the request succeeded. See `addMixesToCollection`
	/// for the fallback when the response body doesn't decode.
	public func removeMixesFromCollection(mixIds: [String]) async -> Bool {
		await changeMixes(mixIds: mixIds, removing: true)
	}

	private func changeMixes(mixIds: [String], removing: Bool) async -> Bool {
		let parameters = [
			"mixIds": mixIds.joined(separator: ","),
			"onArtifactNotFound": "FAIL"
		]
		guard let url = Self.v2URL(path: "favorites/mixes/\(removing ? "remove" : "add")") else { return false }
		do {
			let response = try await v2Put(url: url, parameters: parameters)
			guard response.statusCode == 200 else { return false }
			// The success body shape is unverified, so a 200 whose body doesn't
			// decode still counts as success; when it does decode, the change
			// confirms whether the mixes were actually added/removed.
			guard let change = try? JSONDecoder.custom.decode(MixCollectionChange.self, from: response.data) else {
				return true
			}
			let rejected = removing ? change.itemsNotRemoved : change.itemsNotAdded
			return !mixIds.contains { rejected?.contains($0) == true }
		} catch {
			return false
		}
	}
}
