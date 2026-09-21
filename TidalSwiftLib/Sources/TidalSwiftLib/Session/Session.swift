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

	/// In-memory lyrics cache shared by every `LyricsResolver` built from this
	/// session. Scoping it to the long-lived session (rather than a resolver
	/// owned by a view) is what lets resolved lyrics survive the Now Playing
	/// drawer or the lyrics panel being torn down and rebuilt.
	let lyricsCache = LyricsCache()

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

// MARK: - v2 home feed

extension Session {
	/// Fetches a v2 home feed page. `slug` is one of `static`, `editorial`, `uploads`.
	///
	/// Uses the user's locale, falling back to `en_US` (the locale the endpoint
	/// was verified with) when the first request yields no feed.
	///
	/// `deviceType`/`platform` override the request variant; when omitted, the
	/// shared feed variant is used (see `homeFeedVariant`).
	public func homeFeed(
		slug: String,
		cursor: String? = nil,
		deviceType: String? = nil,
		platform: String? = nil
	) async -> HomeFeedV2? {
		let deviceType = deviceType ?? Self.homeFeedVariant.deviceType
		let platform = platform ?? Self.homeFeedVariant.platform
		if let feed = await homeFeed(
			slug: slug, cursor: cursor,
			locale: Self.localeParameter, deviceType: deviceType, platform: platform
		) {
			return feed
		}
		guard Self.localeParameter != Self.homeFeedFallbackLocale else { return nil }
		return await homeFeed(
			slug: slug, cursor: cursor,
			locale: Self.homeFeedFallbackLocale, deviceType: deviceType, platform: platform
		)
	}

	private func homeFeed(
		slug: String,
		cursor: String?,
		locale: String,
		deviceType: String,
		platform: String
	) async -> HomeFeedV2? {
		var parameters = sessionParameters
		// The official client sends no `limit`; the feed paginates via `cursor`.
		parameters.removeValue(forKey: "limit")
		parameters["deviceType"] = deviceType
		parameters["platform"] = platform
		parameters["locale"] = locale
		parameters["timeOffset"] = Self.timeOffsetParameter
		if let cursor {
			parameters["cursor"] = cursor
		}
		guard let url = Self.v2URL(path: "home/feed/\(slug)") else { return nil }
		do {
			let response: HomeFeedV2 = try await v2Get(url: url, parameters: parameters)
			return response
		} catch {
			return nil
		}
	}

	/// The request variant the feed is served with.
	///
	/// `DESKTOP`/`DESKTOP` is what the official desktop client sends (per its
	/// telemetry) and, with the corrected `clientVersion`, returns the full
	/// section set for all three slugs. `BROWSER`/`WEB` also works at that
	/// version; `DESKTOP` is preferred as the closer match.
	private static let homeFeedVariant = (deviceType: "DESKTOP", platform: "DESKTOP")

	/// Fetches a v2 "view all" page. `path` is a module's relative `viewAll`
	/// path (e.g. `home/pages/DAILY_MIXES/view-all`).
	///
	/// Uses the user's locale, falling back to `en_US` (the locale the endpoint
	/// was verified with) when the first request yields no feed.
	///
	/// `deviceType`/`platform` override the request variant; when omitted, the
	/// shared feed variant is used (see `homeFeedVariant`).
	public func homeFeedViewAll(
		path: String,
		limit: Int = 50,
		offset: Int = 0,
		deviceType: String? = nil,
		platform: String? = nil
	) async -> HomeFeedViewAll? {
		let deviceType = deviceType ?? Self.homeFeedVariant.deviceType
		let platform = platform ?? Self.homeFeedVariant.platform
		if let viewAll = await homeFeedViewAll(
			path: path, limit: limit, offset: offset,
			locale: Self.localeParameter, deviceType: deviceType, platform: platform
		) {
			return viewAll
		}
		guard Self.localeParameter != Self.homeFeedFallbackLocale else { return nil }
		return await homeFeedViewAll(
			path: path, limit: limit, offset: offset,
			locale: Self.homeFeedFallbackLocale, deviceType: deviceType, platform: platform
		)
	}

	private func homeFeedViewAll(
		path: String,
		limit: Int,
		offset: Int,
		locale: String,
		deviceType: String,
		platform: String
	) async -> HomeFeedViewAll? {
		var parameters = sessionParameters
		parameters["deviceType"] = deviceType
		parameters["platform"] = platform
		parameters["locale"] = locale
		parameters["limit"] = String(limit)
		parameters["offset"] = String(offset)
		parameters["timeOffset"] = Self.timeOffsetParameter
		guard let url = Self.v2URL(path: path) else { return nil }
		do {
			let response: HomeFeedViewAll = try await v2Get(url: url, parameters: parameters)
			return response
		} catch {
			return nil
		}
	}

	/// The locale the v2 feed was verified with. Used as a fallback when the
	/// user's locale yields no feed, since the endpoint rejects some locales.
	private static let homeFeedFallbackLocale = "en_US"

	/// Current UTC offset as `±HH:MM`, as the v2 feed expects.
	private static var timeOffsetParameter: String {
		let seconds = TimeZone.current.secondsFromGMT()
		let sign = seconds < 0 ? "-" : "+"
		let absolute = abs(seconds)
		return String(format: "%@%02d:%02d", sign, absolute / 3600, (absolute % 3600) / 60)
	}

	/// Builds a v2 URL from a relative path. Returns `nil` for a path that can't
	/// form a valid URL (e.g. a malformed server-supplied `viewAll` path) instead
	/// of crashing.
	private static func v2URL(path: String) -> URL? {
		URLComponents(string: "\(AuthInformation.APIV2Location)/\(path)")?.url
	}

	/// Performs an authenticated GET against the v2 API. The v2 API requires the
	/// `x-tidal-client-version` header, which `Network.request` doesn't support,
	/// so this builds the request itself (mirroring `Requests.swift`'s refresh
	/// and retry-on-401 behaviour).
	func v2Get<Result: Decodable>(url: URL, parameters: [String: String]) async throws -> Result {
		try? await refreshAccessTokenIfNeeded()
		let response = try await Self.v2Request(url: url, parameters: parameters, accessToken: config.accessToken, xTidalToken: config.apiToken)
		guard response.statusCode == 401 else {
			return try JSONDecoder.custom.decode(Result.self, from: response.data)
		}
		try await refreshAccessToken()
		let retry = try await Self.v2Request(url: url, parameters: parameters, accessToken: config.accessToken, xTidalToken: config.apiToken)
		return try JSONDecoder.custom.decode(Result.self, from: retry.data)
	}

	private static func v2Request(url: URL, parameters: [String: String], accessToken: String, xTidalToken: String) async throws -> Response {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			throw SessionError.unexpectedResponse
		}
		var queryItems = components.queryItems ?? []
		for (name, value) in parameters {
			queryItems.removeAll { $0.name == name }
			queryItems.append(URLQueryItem(name: name, value: value))
		}
		components.queryItems = queryItems
		guard let requestURL = components.url else {
			throw SessionError.unexpectedResponse
		}

		var request = URLRequest(url: requestURL)
		request.httpMethod = "GET"
		request.setValue(accessToken, forHTTPHeaderField: "Authorization")
		request.setValue(xTidalToken, forHTTPHeaderField: "X-Tidal-Token")
		request.setValue(AuthInformation.clientVersion, forHTTPHeaderField: "x-tidal-client-version")
		request.setValue(AuthInformation.tidalClientUserAgent, forHTTPHeaderField: "User-Agent")

		let (data, response) = try await URLSession.shared.data(for: request)
		return Response(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode, etag: nil)
	}
}
