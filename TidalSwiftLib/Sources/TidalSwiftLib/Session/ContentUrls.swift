//
//  ContentUrls.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

/// Decodes the base64 BTS manifest body a `TrackPlaybackInfo` response carries,
/// whether the caller wants the stereo, hi-res or Atmos rendition. A body that is
/// not base64 JSON, or not a BTS manifest, returns nil so the caller keeps looking.
private func decodedBTSManifest(_ response: TrackPlaybackInfo) -> BTSManifest? {
	guard let data = Data(base64Encoded: response.manifest) else { return nil }
	return try? JSONDecoder().decode(BTSManifest.self, from: data)
}

/// The `/playbackinfopostpaywall` response reduced to what a caller acts on: a
/// playable URL and whether that rendition is actually Dolby Atmos.
struct AcceptedPlaybackManifest {
	let url: URL
	let isDolbyAtmos: Bool
}

/// Reads a `TrackPlaybackInfo` into the decision the manifest fallback needs,
/// with no request and no session, so the decision can be tested directly.
enum PlaybackManifestPolicy {
	/// Accepts only an unencrypted BTS manifest. The Atmos flag is read from the
	/// response, never assumed from the caller expecting Atmos: a stereo track
	/// whose `streamUrl` is refused lands here too, and must not be labelled
	/// Atmos. Matches `dolbyAtmosUrl`'s evidence — the response's `audioMode` plus,
	/// when the manifest carries one, the `eac3` codec. DASH and encrypted
	/// manifests are refused so `bestAudioUrl` keeps looking.
	static func accept(_ response: TrackPlaybackInfo) -> AcceptedPlaybackManifest? {
		guard response.manifestMimeType == "application/vnd.tidal.bts",
			  let manifest = decodedBTSManifest(response) else {
			return nil
		}
		if let encryption = manifest.encryptionType, encryption != "NONE" {
			return nil
		}
		guard let url = manifest.urls.first?.upgradedToHTTPS else { return nil }
		let isDolbyAtmos = response.audioMode == .dolbyAtmos
			&& (manifest.codecs == nil || manifest.codecs == "eac3")
		return AcceptedPlaybackManifest(url: url, isDolbyAtmos: isDolbyAtmos)
	}
}

/// A desktop `playbackinfo` response reduced to what the hi-res route needs: a
/// direct URL, the wrapped key that decrypts it, and the format the host says it
/// is serving. `bitDepth`/`sampleRate` are the manifest's own description of the
/// rendition (the file read cannot report them for FLAC), and are optional so a
/// response that omits them stays unknown rather than guessed.
struct AcceptedHiResManifest {
	let url: URL
	let keyId: String
	var bitDepth: Int? = nil
	var sampleRate: Int? = nil
}

/// Reads a desktop `playbackinfo` response into the hi-res decision, with no
/// request and no session, so the decision can be tested directly. Mirrors
/// `PlaybackManifestPolicy`: only a stereo BTS FLAC manifest encrypted with Tidal's
/// legacy `OLD_AES` is usable, so anything else is refused and the caller keeps
/// today's path. A DASH body, an Atmos rendition, or a manifest encrypted with a
/// scheme this app cannot unwrap all land here.
enum HiResManifestPolicy {
	static func accept(_ response: TrackPlaybackInfo) -> AcceptedHiResManifest? {
		guard response.audioMode == .stereo,
			  response.manifestMimeType == "application/vnd.tidal.bts",
			  let manifest = decodedBTSManifest(response),
			  manifest.codecs == "flac",
			  manifest.encryptionType == "OLD_AES",
			  let keyId = manifest.keyId,
			  let url = manifest.urls.first?.upgradedToHTTPS else {
			return nil
		}
		return AcceptedHiResManifest(url: url, keyId: keyId, bitDepth: response.bitDepth, sampleRate: response.sampleRate)
	}
}

/// Reads a desktop `playbackinfo` response into the DASH decision, with no request
/// and no session, so the decision can be tested directly. Measured 2026-10-05: at
/// `HIGH`/`LOW` Tidal refuses `streamUrl` and answers the desktop endpoint with an
/// `application/dash+xml` manifest whose payload is an unencrypted AAC MPD. Only an
/// MPD this app can assemble is accepted; anything else returns nil.
enum DashManifestPolicy {
	static func accept(_ response: TrackPlaybackInfo) -> DashAudioManifest? {
		guard response.manifestMimeType == "application/dash+xml" else { return nil }
		return try? DashAudioManifest(base64Manifest: response.manifest)
	}
}

extension Session {
	/// Why the desktop route did or did not produce a stream. The last two cases are
	/// the same to the caller (it falls back); they are separate so the log can say
	/// whether the track has no stereo rendition or the request failed.
	enum HiResStereoResolution {
		case resolved(AcceptedHiResManifest)
		case noStereoRendition
		case failed
	}

	/// Resolves a track through the desktop client's `playbackinfo`, which serves
	/// the 24-bit stereo rendition when the session carries a `cuk` claim.
	///
	/// The endpoint lives on `desktop.tidal.com` and is asked the way the official
	/// desktop client asks it: `audioquality=HI_RES_LOSSLESS`, `playbackmode=STREAM`,
	/// `assetpresentation=FULL` plus the same request variant every other v1 call
	/// sends (`countryCode`/`deviceType`/`platform`/`locale`), the desktop
	/// `X-Tidal-Token`, the `x-tidal-client-version` header, the desktop user agent
	/// and a fresh streaming session id per request. A session without `cuk` is
	/// answered Atmos here, which the policy refuses, so the same call is safe to
	/// make unconditionally.
	func hiResStereoStream(trackId: Int, audioQuality: AudioQuality = .max) async -> HiResStereoResolution {
		do {
			let response: TrackPlaybackInfo = try await desktopPlaybackInfo(trackId: trackId, audioQuality: audioQuality)
			guard let accepted = HiResManifestPolicy.accept(response) else { return .noStereoRendition }
			return .resolved(accepted)
		} catch {
			return .failed
		}
	}

	private func desktopPlaybackInfo(trackId: Int, audioQuality: AudioQuality) async throws -> TrackPlaybackInfo {
		try? await refreshAccessTokenIfNeeded()
		var parameters: [String: String] = [
			"audioquality": audioQuality.rawValue,
			"playbackmode": "STREAM",
			"assetpresentation": "FULL",
			"deviceType": "BROWSER",
			"platform": "WEB",
			"locale": Self.localeParameter
		]
		if let countryCode {
			parameters["countryCode"] = countryCode
		}
		var components = URLComponents(string: "\(HiResStreaming.desktopAPILocation)/tracks/\(trackId)/playbackinfo")!
		components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
		var request = URLRequest(url: components.url!)
		request.setValue(config.accessToken, forHTTPHeaderField: "Authorization")
		request.setValue(AuthInformation.DesktopClientID, forHTTPHeaderField: "X-Tidal-Token")
		request.setValue(AuthInformation.clientVersion, forHTTPHeaderField: "x-tidal-client-version")
		request.setValue(AuthInformation.tidalClientUserAgent, forHTTPHeaderField: "User-Agent")
		request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "x-tidal-streamingsessionid")

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
			throw SessionError.unexpectedResponse
		}
		let info = try JSONDecoder.custom.decode(TrackPlaybackInfo.self, from: data)
		if let bitDepth = info.bitDepth, let sampleRate = info.sampleRate {
			print("[PLAYBACK] hi-res stereo: desktop playbackinfo answered \(info.audioMode?.rawValue ?? "?") \(bitDepth)-bit \(sampleRate) Hz")
		}
		return info
	}

	/// Resolves a High/Low track to a DASH audio manifest through the desktop
	/// client's `playbackinfo`, the same call the hi-res route uses.
	///
	/// At `HIGH`/`LOW` the stereo `streamUrl` is refused and the endpoint answers an
	/// unencrypted AAC MPD instead, which this app assembles into a local file. The
	/// other tiers answer BTS, which `DashManifestPolicy` refuses, so the caller only
	/// asks for the tiers where DASH is expected.
	func dashAudioManifest(trackId: Int, audioQuality: AudioQuality) async -> DashAudioManifest? {
		do {
			let response: TrackPlaybackInfo = try await desktopPlaybackInfo(trackId: trackId, audioQuality: audioQuality)
			return DashManifestPolicy.accept(response)
		} catch {
			return nil
		}
	}

	func audioUrl(trackId: Int, audioQuality: AudioQuality) async -> URL? {
		var parameters = sessionParameters
		parameters["soundQuality"] = "\(audioQuality.rawValue)"
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/streamUrl")!
		do {
			let response: AudioUrl = try await get(url: url, parameters: parameters)

//			print("""
//			Track ID: \(response.trackId),
//			Quality: \(response.soundQuality.rawValue),
//			Codec: \(response.codec)
//			""")

			return response.url.upgradedToHTTPS
		} catch {
			return nil
		}
	}

	/// The Dolby Atmos rendition of a track, which `streamUrl` refuses.
	///
	/// Only an unencrypted E-AC-3 manifest is usable; anything else (a stereo
	/// fallback, a DASH or DRM-wrapped manifest) returns nil so the caller keeps
	/// the stereo path.
	func dolbyAtmosUrl(trackId: Int) async -> URL? {
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/playbackinfopostpaywall")!
		var parameters = sessionParameters
		parameters["audioquality"] = AudioQuality.high.rawValue
		parameters["playbackmode"] = "STREAM"
		parameters["assetpresentation"] = "FULL"
		parameters["immersiveaudio"] = "true"
		do {
			let response: TrackPlaybackInfo = try await get(url: url, parameters: parameters)
			guard response.audioMode == .dolbyAtmos,
				  response.manifestMimeType == "application/vnd.tidal.bts",
				  let manifest = decodedBTSManifest(response),
				  manifest.codecs == "eac3",
				  manifest.encryptionType == "NONE" else {
				return nil
			}
			return manifest.urls.first?.upgradedToHTTPS
		} catch {
			return nil
		}
	}

	/// Resolves a track to a playable streaming URL.
	///
	/// When `preferDolbyAtmos` is set and the track has an Atmos rendition, that
	/// rendition wins even when a stereo one exists. Atmos is not a tier in the
	/// ladder below, so it is attempted once and never memoised; `isDolbyAtmos`
	/// reports whether the returned URL is that rendition, so the caller can label
	/// the stream that actually plays instead of the track's capabilities.
	public func bestAudioUrl(trackId: Int, preferredQuality: AudioQuality, preferDolbyAtmos: Bool = false) async -> (url: URL, quality: AudioQuality, isDolbyAtmos: Bool)? {
		// The preference branch: ask for the Atmos rendition explicitly
		// (`immersiveaudio=true` inside `dolbyAtmosUrl`) before touching the ladder.
		if preferDolbyAtmos, let atmosUrl = await dolbyAtmosUrl(trackId: trackId) {
			return (atmosUrl, preferredQuality, true)
		}
		let descending: [AudioQuality] = [.max, .high, .medium, .low]
		guard let preferredIndex = descending.firstIndex(of: preferredQuality) else {
			return nil
		}
		var startIndex = preferredIndex
		if let resolvedIndex = bestResolvedAudioQualities[trackId].flatMap({ descending.firstIndex(of: $0) }),
			resolvedIndex > preferredIndex {
			startIndex = resolvedIndex
		}
		for quality in descending[startIndex...] {
			if let url = await audioUrl(trackId: trackId, audioQuality: quality) {
				bestResolvedAudioQualities[trackId] = quality
				return (url, quality, false)
			}
			// The ladder fallback: Tidal refuses the stereo stream for an Atmos
			// track, so the manifest endpoint serves it instead. Unlike the preference
			// branch above, this path does not ask for Atmos — it is where a track
			// lands whenever `streamUrl` refuses — so the rendition is taken from the
			// response, not assumed.
			if let manifest = await playbackManifestUrl(trackId: trackId, audioQuality: quality) {
				bestResolvedAudioQualities[trackId] = quality
				return (manifest.url, quality, manifest.isDolbyAtmos)
			}
		}
		return nil
	}

	func videoUrl(videoId: Int) async -> URL? {
		let url = URL(string: "\(AuthInformation.APILocation)/videos/\(videoId)/playbackinfo")!
		var parameters = sessionParameters
		parameters["videoquality"] = "HIGH"
		parameters["playbackmode"] = "STREAM"
		parameters["assetpresentation"] = "FULL"
		do {
			let response: VideoPlaybackInfo = try await get(url: url, parameters: parameters)
			guard let decodedManifestData = Data(base64Encoded: response.manifest) else { return nil }
			let manifest = try JSONDecoder().decode(VideoManifest.self, from: decodedManifestData)
			guard let streamUrlString = manifest.urls.first else { return nil }
			guard let streamUrl = URL(string: streamUrlString) else { return nil }
			return streamUrl
		} catch {
			return nil
		}
	}

	/// Resolves a track through `/tracks/{id}/playbackinfopostpaywall`, the fallback
	/// for tracks `streamUrl` refuses. `streamUrl` answers an Atmos-only track with
	/// HTTP 401 subStatus 4005 "Asset is not ready for playback"; this endpoint serves
	/// that track's unencrypted E-AC-3 (`eac3`) BTS manifest instead. Returns nil for
	/// non-BTS manifests: Tidal answers the High/Low tiers with DASH, which AVPlayer
	/// cannot play, while hi-res answers BTS. Whether the accepted rendition is Atmos
	/// is decided by `PlaybackManifestPolicy` from the response, not assumed from the
	/// caller.
	func playbackManifestUrl(trackId: Int, audioQuality: AudioQuality) async -> AcceptedPlaybackManifest? {
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/playbackinfopostpaywall")!
		var parameters = sessionParameters
		parameters["audioquality"] = audioQuality.rawValue
		parameters["playbackmode"] = "STREAM"
		parameters["assetpresentation"] = "FULL"
		do {
			let response: TrackPlaybackInfo = try await get(url: url, parameters: parameters)
			return PlaybackManifestPolicy.accept(response)
		} catch {
			return nil
		}
	}

	func pathExtension(for audioQuality: AudioQuality) -> String {
		switch audioQuality {
		case .low, .medium:
			return "m4a"
		case .high, .max:
			return "flac"
		}
	}

	/// The download file extension for a resolved stream. An Atmos track is served
	/// as an E-AC-3 MP4, so the URL's extension wins over the quality tier's.
	func pathExtension(for url: URL, audioQuality: AudioQuality) -> String {
		url.pathExtension.isEmpty ? pathExtension(for: audioQuality) : url.pathExtension
	}
}

extension URL {
	/// Applied to every TIDAL URL this app fetches, so a plain-http manifest entry
	/// cannot be read in the clear where ATS refuses it. `nonisolated` because the
	/// DASH assembler reads it off the main actor.
	nonisolated var upgradedToHTTPS: URL {
		guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
		guard components.scheme?.lowercased() == "http" else { return self }
		components.scheme = "https"
		return components.url ?? self
	}
}
