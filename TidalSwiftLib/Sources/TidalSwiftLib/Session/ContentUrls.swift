//
//  ContentUrls.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

/// Decodes a base64 BTS manifest; nil for anything else, so the caller keeps looking.
private func decodedBTSManifest(_ response: TrackPlaybackInfo) -> BTSManifest? {
	guard let data = Data(base64Encoded: response.manifest) else { return nil }
	return try? JSONDecoder().decode(BTSManifest.self, from: data)
}

struct AcceptedPlaybackManifest {
	let url: URL
	let isDolbyAtmos: Bool
}

enum PlaybackManifestPolicy {
	/// Accepts only an unencrypted BTS manifest. The Atmos flag comes from the response, never
	/// assumed from the caller: a refused stereo track lands here too and must not be labelled
	/// Atmos. DASH and encrypted manifests are refused so `bestAudioUrl` keeps looking.
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

/// `bitDepth`/`sampleRate` come from the manifest, since the file read cannot report
/// them for FLAC; optional, so an omitted value stays unknown rather than guessed.
struct AcceptedHiResManifest {
	let url: URL
	let keyId: String
	var bitDepth: Int? = nil
	var sampleRate: Int? = nil
}

enum HiResManifestPolicy {
	/// Only a stereo BTS FLAC manifest encrypted with Tidal's legacy `OLD_AES` is usable.
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

enum DashManifestPolicy {
	/// At `HIGH`/`LOW` Tidal refuses `streamUrl` and answers an unencrypted AAC
	/// `application/dash+xml` MPD; anything this app cannot assemble returns nil.
	static func accept(_ response: TrackPlaybackInfo) -> DashAudioManifest? {
		guard response.manifestMimeType == "application/dash+xml" else { return nil }
		return try? DashAudioManifest(base64Manifest: response.manifest)
	}
}

extension Session {
	/// The last two cases fall back the same way; they are separate so the log can say why.
	enum HiResStereoResolution {
		case resolved(AcceptedHiResManifest)
		case noStereoRendition
		case failed
	}

	/// Resolves a track through the desktop client's `playbackinfo`, which serves the
	/// 24-bit stereo rendition when the session carries a `cuk` claim. A session without
	/// `cuk` is answered Atmos, which the policy refuses, so the call is safe to make.
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

	/// Only the `HIGH`/`LOW` tiers answer DASH; the rest answer BTS, which the policy refuses.
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


			return response.url.upgradedToHTTPS
		} catch {
			return nil
		}
	}

	/// The Atmos rendition, which `streamUrl` refuses. Only an unencrypted E-AC-3
	/// manifest is usable; anything else returns nil so the caller keeps the stereo path.
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
	/// When `preferDolbyAtmos` is set and an Atmos rendition exists, it wins even over
	/// stereo. Atmos is not a tier in the ladder below, so it is attempted once and
	/// never memoised; `isDolbyAtmos` reports the rendition that actually plays, not the
	/// track's capabilities.
	public func bestAudioUrl(trackId: Int, preferredQuality: AudioQuality, preferDolbyAtmos: Bool = false) async -> (url: URL, quality: AudioQuality, isDolbyAtmos: Bool)? {
		// Ask for the Atmos rendition explicitly (`immersiveaudio=true` inside
		// `dolbyAtmosUrl`) before touching the ladder.
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
			// `streamUrl` refuses an Atmos track, so the manifest endpoint serves it; this path
			// does not ask for Atmos, so the rendition comes from the response.
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

	/// The fallback for tracks `streamUrl` refuses with HTTP 401 subStatus 4005 "Asset
	/// is not ready for playback". Tidal serves that track's unencrypted E-AC-3 BTS
	/// manifest, the High/Low tiers DASH (unplayable by AVPlayer) and hi-res BTS.
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

	/// The URL's extension wins over the tier's: an Atmos track is served as an E-AC-3 MP4.
	func pathExtension(for url: URL, audioQuality: AudioQuality) -> String {
		url.pathExtension.isEmpty ? pathExtension(for: audioQuality) : url.pathExtension
	}
}

extension URL {
	/// A plain-http manifest entry cannot be read where ATS refuses it; `nonisolated` because
	/// the DASH assembler reads it off the main actor.
	nonisolated var upgradedToHTTPS: URL {
		guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
		guard components.scheme?.lowercased() == "http" else { return self }
		components.scheme = "https"
		return components.url ?? self
	}
}
