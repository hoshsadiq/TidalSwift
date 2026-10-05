//
//  ContentUrls.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

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
			  let data = Data(base64Encoded: response.manifest),
			  let manifest = try? JSONDecoder().decode(BTSManifest.self, from: data) else {
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

extension Session {
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
				  let decodedManifestData = Data(base64Encoded: response.manifest),
				  let manifest = try? JSONDecoder().decode(BTSManifest.self, from: decodedManifestData),
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
	/// for tracks `streamUrl` refuses. Dolby Atmos-only tracks answer
	/// HTTP 401 subStatus 4005 "Asset is not ready for playback". Returns nil for
	/// non-BTS manifests: hi-res answers with DASH, which AVPlayer cannot play.
	/// Whether the accepted rendition is Atmos is decided by `PlaybackManifestPolicy`
	/// from the response, not assumed from the caller.
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
	fileprivate var upgradedToHTTPS: URL {
		guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
		guard components.scheme?.lowercased() == "http" else { return self }
		components.scheme = "https"
		return components.url ?? self
	}
}
