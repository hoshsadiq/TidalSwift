//
//  FeedActivities.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

// MARK: - v2 feed activities

extension Session {
	/// Fetches the user's feed activities (`/v2/feed/activities`).
	///
	/// Activities are only created for events that happen *after* the user
	/// follows an artist — there is no backfill, so a fresh follow yields an
	/// empty feed until the artist releases something new.
	///
	/// Uses the user's locale, falling back to `en_US` (the locale the endpoint
	/// was verified with) when the first request fails. Returns `nil` when no
	/// user is logged in or the request fails; an empty array is a valid
	/// response for an account without activities.
	public func feedActivities() async -> [FeedActivity]? {
		guard let userId else { return nil }
		if let activities = await feedActivities(userId: String(userId), locale: Self.localeParameter) {
			return activities
		}
		guard Self.localeParameter != Self.homeFeedFallbackLocale else { return nil }
		return await feedActivities(userId: String(userId), locale: Self.homeFeedFallbackLocale)
	}

	private func feedActivities(userId: String, locale: String) async -> [FeedActivity]? {
		var parameters = sessionParameters
		// The endpoint returns a fixed-size list; `limit`/`offset`/`cursor` are
		// not accepted.
		parameters.removeValue(forKey: "limit")
		parameters["userId"] = userId
		parameters["locale"] = locale
		guard let url = Self.v2URL(path: "feed/activities") else { return nil }
		do {
			let response: FeedResponse = try await v2Get(url: url, parameters: parameters)
			return response.activities
		} catch {
			return nil
		}
	}
}
