//
//  Config.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

enum AuthInformation {
    static let OAuthClientID = "4ywnjRfroi84hz7i"
    static let OAuthClientSecret = "7cNdrLt3NIQg0CHEpMDjcbV38XlwVdstczHqf59QiI0="
	static let scope = "r_usr+w_usr"
	// The official desktop client (PKCE): no client secret, and its token's `cid` 7785 /
	// `cuk` claims make Tidal serve hi-res stereo rather than Atmos.
	static let DesktopClientID = "mhPVJJEBNRzVjr2p"
	static let DesktopAuthorizeLocation = "https://login.tidal.com/authorize"
	// The authorize host is login.tidal.com; the exchange happens on auth.tidal.com.
	static let DesktopTokenLocation = "https://auth.tidal.com/v1/oauth2/token"
	// Tidal binds the session to a client unique key sent on the code exchange; without it
	// the token has no `cuk` claim and Atmos-capable tracks fall back to the Atmos rendition,
	// which only a High or Max ceiling plays.
	// Generated once per install and kept, as the server treats it as identifying this client.
	static let DesktopUniqueKeyDefaultsKey = "desktopClientUniqueKey"
	// Fixed by the desktop client registration; a loopback redirect is refused.
	static let DesktopRedirectURI = "tidal://login/auth"
    static let APILocation = "https://api.tidal.com/v1"
	// The v2 feed is on `tidal.com`, not `api.tidal.com`; both answer identically.
    static let APIV2Location = "https://tidal.com/v2"
	// The v2 catalog API is on a different host: `tidal.com/v2` serves `home/feed/*` but 404s
	// for `/tracks/{id}`, and `openapi.tidal.com/v2` is the reverse.
	static let APIV2OpenAPILocation = "https://openapi.tidal.com/v2"
	static let LRCLIBLocation = "https://lrclib.net"
	// The official desktop client's UA. Tidal requests present as the real client, LRCLIB as
	// Safari (`safariUserAgent`); neither names this app.
	static let tidalClientUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) TIDAL/2.43.2 Chrome/150.0.7871.129 Electron/43.2.0 Safari/537.36"
	static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"
	// Required by the v2 API (`x-tidal-client-version`); without it, HTTP 400. The value
	// also gates the home feed: semver below ~2026.4 is treated as legacy and gets
	// `TRACK_LIST`/`VERTICAL_LIST` track rows instead of `COMPACT_GRID_CARD`. `2026.09.15` is
	// the official desktop client's version and returns the full feed.
	static let clientVersion = "2026.09.15"
    static let AuthLocation = "https://auth.tidal.com/v1/oauth2"
    static let ImageLocation = "https://resources.tidal.com/images"
}

public class Config {
	var accessToken: String
	var refreshToken: String
	var clientID: String
	var apiToken: String
	public var offlineAudioQuality: AudioQuality
	var imageSize: Int
	var tokenExpirationDate: Date?

	public init(
		accessToken: String,
		refreshToken: String,
		clientID: String,
		apiToken: String? = nil,
		offlineAudioQuality: AudioQuality,
		imageLocation: String = "",
		imageSize: Int = 1280,
		tokenExpirationDate: Date? = nil
	) {
		self.accessToken = accessToken
		self.refreshToken = refreshToken
		self.clientID = clientID

		if let token = apiToken {
			self.apiToken = token
		} else {
			self.apiToken = "_DSTon1kC8pABnTw" // Direct ALAC, 1080p Videos
		}

		self.offlineAudioQuality = offlineAudioQuality


		self.imageSize = imageSize
		self.tokenExpirationDate = tokenExpirationDate
	}
}

extension Config {
	/// The built-in client id `Config.load()` falls back to when a stored config names none.
	/// Exposed so a reader outside the library decodes the stored config exactly as the app
	/// does, rather than substituting an empty id that would break a token refresh.
	public static var builtInClientID: String { AuthInformation.OAuthClientID }
}
