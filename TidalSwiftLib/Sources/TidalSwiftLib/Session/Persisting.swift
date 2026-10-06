//
//  Persisting.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

struct PersistentInformation {
	var sessionId: String
	var countryCode: String
	var userId: Int
}

extension Session {
	public func loadSession() -> Bool {
		let persistentInformationOptional: [String: String]? =
			UserDefaults.standard.dictionary(forKey: "Session Information") as? [String: String]

		guard let persistentInformation = persistentInformationOptional else {
			displayError(title: "Couldn't load Session", content: "Persistent Session Information doesn't exist")
			return false
		}

		countryCode = persistentInformation["countryCode"]
		userId = Int(persistentInformation["userId"]!)
		favorites = Favorites(session: self, userId: userId!)
		return true
	}

	public func saveSession() {
		// A token is what makes this a session, so a logged-out save writes nothing.
		// This runs from `saveState` on quit and on every scene-phase change, and
		// writing here is what put a stale "Session Information" back after a logout
		// and made the next launch report a session with no token behind it.
		guard !config.refreshToken.isEmpty else { return }
		guard let countryCode = countryCode,
			  let userId = userId else {
			displayError(title: "Couldn't save Session Information",
						 content: "Session Information wasn't set yet. You're probably not logged in.")
			return
		}

		let persistentInformation: [String: String] = ["countryCode": countryCode,
													   "userId": String(userId)]

		UserDefaults.standard.set(persistentInformation, forKey: "Session Information")
	}

	public func saveConfig() {
		var persistentInformation: [String: String?] = [
			"accessToken": config.accessToken,
			"refreshToken": config.refreshToken,
			"clientID": config.clientID,
			"apiToken": config.apiToken,
			"offlineAudioQuality": config.offlineAudioQuality.rawValue,
			"imageSize": String(config.imageSize)
		]
		if let tokenExpirationDate = config.tokenExpirationDate {
			persistentInformation["tokenExpirationDate"] = String(tokenExpirationDate.timeIntervalSince1970)
		}

		UserDefaults.standard.set(persistentInformation, forKey: "Config Information")
	}

	/// The only keys a logout owns: what `saveConfig` and `saveSession` write.
	/// Everything else in the app's UserDefaults domain — the `OfflineDB:*`
	/// database and the offline preferences — says which audio files the offline
	/// library holds. `Offline.init` deletes every file missing from that database
	/// at launch, so removing the whole persistent domain here emptied the
	/// library on the next start.
	private static let sessionKeys = ["Config Information", "Session Information"]

	public func deletePersistentInformation() {
		for key in Self.sessionKeys {
			UserDefaults.standard.removeObject(forKey: key)
		}
	}
}

extension Config {
	static func load() -> Config? {
		let persistentInformationOptional: [String: String]? =
			UserDefaults.standard.dictionary(forKey: "Config Information") as? [String: String]

		guard let persistentInformation = persistentInformationOptional else {
			displayError(title: "Couldn't load Config", content: "Persistent Config doesn't exist")
			return nil
		}

		guard let accessToken = persistentInformation["accessToken"],
			  let refreshToken = persistentInformation["refreshToken"],
			  let apiToken = persistentInformation["apiToken"],
			  let offlineAudioQualityString = persistentInformation["offlineAudioQuality"],
			  let offlineAudioQuality = AudioQuality(rawValue: offlineAudioQualityString),
			  let imageSizeString = persistentInformation["imageSize"],
			  let imageSize = Int(imageSizeString)
		else {
			displayError(title: "Couldn't load Config", content: "Missing part of Persistent Config.")
			return nil
		}

		let clientID = persistentInformation["clientID"] ?? AuthInformation.OAuthClientID

		var tokenExpirationDate: Date?
		if let expirationString = persistentInformation["tokenExpirationDate"],
		   let expirationInterval = Double(expirationString) {
			tokenExpirationDate = Date(timeIntervalSince1970: expirationInterval)
		}

		return Config(
			accessToken: accessToken,
			refreshToken: refreshToken,
			clientID: clientID,
			apiToken: apiToken,
			offlineAudioQuality: offlineAudioQuality,
			imageSize: imageSize,
			tokenExpirationDate: tokenExpirationDate
		)
	}
}
