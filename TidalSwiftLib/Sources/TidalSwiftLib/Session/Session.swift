//
//  Session.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

public class Session {
	public var config: Config

	var countryCode: String?
	public var userId: Int?

	var sessionParameters: [String: String] {
		if countryCode == nil {
			return [:]
		} else {
			return ["countryCode": countryCode!,
					"limit": "999"]
		}

	}

	public var favorites: Favorites?
	public var helpers: Helpers!
	public var playlistEditing: PlaylistEditing!
	var activeTokenRefresh: Task<Void, Error>?
	var bestResolvedAudioQualities: [Int: AudioQuality] = [:]

	public init(config: Config?) {
		if let config = config {
			self.config = config
		} else {
			if let config = Config.load() {
				self.config = config
			} else {
				self.config = Config(
					accessToken: "",
					refreshToken: "",
					clientID: "",
					offlineAudioQuality: .high,
					urlType: .streaming
				)
			}
		}
		helpers = Helpers(session: self)
		playlistEditing = PlaylistEditing(session: self)
	}
}

extension Session {
	/// Fetches any v1 page path (e.g. `pages/home`, `pages/for_you`) relative to
	/// `AuthInformation.APILocation`.
	public func page(path: String) async -> Page? {
		var parameters = sessionParameters
		parameters["deviceType"] = "BROWSER"
		let url = URL(string: "\(AuthInformation.APILocation)/\(path)")!
		do {
			let response: Page = try await get(url: url, parameters: parameters)
			return response
		} catch {
			return nil
		}
	}

	/// Fetches one batch of a pageable list (a module's `pagedList.dataApiPath`)
	/// relative to `AuthInformation.APILocation`.
	public func pagedList(path: String, offset: Int, limit: Int) async -> PagedList? {
		var parameters = sessionParameters
		parameters["deviceType"] = "BROWSER"
		// Unlike the other page endpoints, `pages/data/` rejects requests
		// without a locale (HTTP 400 "locale or deviceType missing").
		parameters["locale"] = Self.localeParameter
		parameters["offset"] = String(offset)
		parameters["limit"] = String(limit)
		let url = URL(string: "\(AuthInformation.APILocation)/\(path)")!
		do {
			let response: PagedList = try await get(url: url, parameters: parameters)
			return response
		} catch {
			return nil
		}
	}

	private static var localeParameter: String {
		let language = Locale.current.language.languageCode?.identifier ?? "en"
		let region = Locale.current.region?.identifier ?? "US"
		return "\(language)_\(region)"
	}
}
