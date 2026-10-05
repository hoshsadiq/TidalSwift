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
	// The official desktop client, for the PKCE login. Unlike ours it needs no
	// client secret, and its token carries the `cid` 7785 / `cuk` claims that
	// make Tidal serve hi-res stereo instead of Atmos.
	static let DesktopClientID = "mhPVJJEBNRzVjr2p"
	static let DesktopAuthorizeLocation = "https://login.tidal.com/authorize"
	// Captured from the official app's own token exchange: the authorize host is
	// login.tidal.com, but the exchange happens on auth.tidal.com.
	static let DesktopTokenLocation = "https://auth.tidal.com/v1/oauth2/token"
	// Tidal binds the session to a client unique key, which the official app sends
	// on the code exchange. Without it the token has no `cuk` claim, and Tidal
	// serves the Atmos rendition instead of the stereo one for Atmos-capable
	// tracks. Generated once per install and kept, because the server treats it as
	// identifying this installation.
	static let DesktopUniqueKeyDefaultsKey = "desktopClientUniqueKey"
	// Fixed by the desktop client registration; a loopback redirect is refused.
	static let DesktopRedirectURI = "tidal://login/auth"
    static let APILocation = "https://api.tidal.com/v1"
	// The official desktop client asks the v2 feed on `tidal.com` (not
	// `api.tidal.com`); both hosts answer identically.
    static let APIV2Location = "https://tidal.com/v2"
	// The v2 catalog API lives on a different host than the v2 feed:
	// `tidal.com/v2` serves `home/feed/*` but 404s for `/tracks/{id}`, while
	// `openapi.tidal.com/v2` is the reverse (verified 2026-09-17).
	static let APIV2OpenAPILocation = "https://openapi.tidal.com/v2"
	// LRCLIB has no auth; only the base URL is needed.
	static let LRCLIBLocation = "https://lrclib.net"
	// The official desktop client's User-Agent, captured 2026-09-17. Tidal
	// requests present as the real client; LRCLIB requests present as Safari
	// (`safariUserAgent`). Neither names this app.
	static let tidalClientUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) TIDAL/2.43.2 Chrome/150.0.7871.129 Electron/43.2.0 Safari/537.36"
	static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15"
	// Required by the v2 API (`x-tidal-client-version`); without it it answers HTTP 400.
	//
	// The value also gates the home feed: a value parsed as semver below ~2026.4
	// (e.g. the old `2026.1.5`) is treated as a legacy client and gets a reduced
	// feed — fewer sections, and track rows typed `TRACK_LIST`/`VERTICAL_LIST`
	// instead of `COMPACT_GRID_CARD`. `2026.09.15` is the official desktop
	// client's version and returns the full feed.
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
