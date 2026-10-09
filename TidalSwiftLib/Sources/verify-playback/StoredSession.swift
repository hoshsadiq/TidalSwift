//
//  StoredSession.swift
//  verify-playback
//
//  Reads the session the TidalSwift app stores, from the app's own UserDefaults domain. A
//  command line tool has no bundle identifier, so `UserDefaults.standard` is the tool's own
//  empty domain rather than the app's; this reader opens the app's domain by name and reads
//  the same keys `Session.Persisting` writes. Read-only and local to the tool, so the library's
//  own session loading is untouched.
//

import Foundation
import TidalSwiftLib

/// Whether a string the tool was handed as a session is one: `Bearer <jwt>`, a three-part
/// JWT. A token that is not was refused before any request reached the catalogue, so the
/// tool can say the session was refused instead of blaming the track.
enum SessionToken {
	static func looksLikeSessionToken(_ token: String) -> Bool {
		let jwt = token.split(separator: " ").last.map(String.init) ?? token
		return jwt.split(separator: ".", omittingEmptySubsequences: false).count == 3
	}
}

enum StoredSession {
	/// The app's defaults domain (`io.hosh.TidalSwift`). Fixed here because a tool without a
	/// bundle identifier cannot derive it from a bundle.
	static let appDefaultsDomain = "io.hosh.TidalSwift"

	enum ConfigResult {
		case stored(Config)
		case missing
		case expired
	}

	/// Decodes `Config Information` the way `Config.load()` does, and reports an empty or
	/// past-expiry access token as expired. A token with no recorded expiry is not expired:
	/// the app refreshes on use, and a missing date is not evidence of a dead token.
	static func config(from defaults: UserDefaults) -> ConfigResult {
		guard let stored = defaults.dictionary(forKey: "Config Information") as? [String: String],
			  let accessToken = stored["accessToken"],
			  let refreshToken = stored["refreshToken"],
			  let apiToken = stored["apiToken"],
			  let qualityString = stored["offlineAudioQuality"],
			  let quality = AudioQuality(rawValue: qualityString),
			  let imageSizeString = stored["imageSize"],
			  let imageSize = Int(imageSizeString)
		else { return .missing }

		var expirationDate: Date?
		if let expirationString = stored["tokenExpirationDate"],
		   let interval = Double(expirationString) {
			expirationDate = Date(timeIntervalSince1970: interval)
		}

		if accessToken.isEmpty { return .expired }
		if let expirationDate, expirationDate <= Date() { return .expired }

		return .stored(Config(
			accessToken: accessToken,
			refreshToken: refreshToken,
			clientID: stored["clientID"] ?? Config.builtInClientID,
			apiToken: apiToken,
			offlineAudioQuality: quality,
			imageSize: imageSize,
			tokenExpirationDate: expirationDate
		))
	}

	/// Applies `Session Information` to a session: the user id `Favorites` needs and the country
	/// code the catalogue requests carry. Best effort, so a run with `TIDAL_TEST_TOKEN` still
	/// works on a machine that holds no stored session information.
	static func apply(to session: Session, from defaults: UserDefaults) {
		guard let stored = defaults.dictionary(forKey: "Session Information") as? [String: String] else { return }
		if let countryCode = stored["countryCode"] {
			session.countryCode = countryCode
		}
		guard let userIdString = stored["userId"], let userId = Int(userIdString) else { return }
		session.userId = userId
		session.favorites = Favorites(session: session, userId: userId)
	}
}
