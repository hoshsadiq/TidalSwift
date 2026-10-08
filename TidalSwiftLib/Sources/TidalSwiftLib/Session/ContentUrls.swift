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

/// Whether a BTS codec string names E-AC-3, the Atmos rendition's codec. The payload is
/// recorded as `eac3`, but the guard must fail closed on the codec rather than trust the
/// response's `audioMode` label: an answer whose codec is E-AC-3 under any spelling is
/// treated as Atmos and let the ceiling decide.
private func isEac3Codec(_ codecs: String?) -> Bool {
	guard let codecs else { return false }
	let normalized = codecs.lowercased().filter { $0.isLetter || $0.isNumber }
	return normalized == "eac3" || normalized == "ec3" || normalized == "ac3"
}

struct AcceptedPlaybackManifest {
	let url: URL
	let isDolbyAtmos: Bool
}

enum PlaybackManifestPolicy {
	/// Accepts only an unencrypted BTS manifest at a ceiling that admits its rendition. The
	/// Atmos flag comes from the response, never assumed from the caller: a refused stereo
	/// track lands here too and must not be labelled Atmos. A codec that names E-AC-3 is
	/// Atmos whatever `audioMode` says, so an answer whose label is missing or mis-spelled is
	/// still refused at a ceiling that does not admit it (`AudioQuality.admitsDolbyAtmos`),
	/// because the ceiling gates the Atmos request too and the endpoint answers Atmos at any
	/// quality. DASH and encrypted manifests are refused so `bestAudioUrl` keeps looking.
	static func accept(_ response: TrackPlaybackInfo, ceiling: AudioQuality) -> AcceptedPlaybackManifest? {
		guard response.manifestMimeType == "application/vnd.tidal.bts",
			  let manifest = decodedBTSManifest(response) else {
			return nil
		}
		if let encryption = manifest.encryptionType, encryption != "NONE" {
			return nil
		}
		guard let url = manifest.urls.first?.upgradedToHTTPS else { return nil }
		let isDolbyAtmos = isEac3Codec(manifest.codecs)
			|| (response.audioMode == .dolbyAtmos && manifest.codecs == nil)
		guard !isDolbyAtmos || ceiling.admitsDolbyAtmos else { return nil }
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
	/// stereo, but only when the ceiling admits Atmos (`AudioQuality.admitsDolbyAtmos`): a
	/// Low or Medium ceiling never plays the ~768 kbps E-AC-3 stream. Atmos is not a tier in
	/// the ladder below, so it is attempted once and never memoised; `isDolbyAtmos` reports
	/// the rendition that actually plays, not the track's capabilities.
	public func bestAudioUrl(trackId: Int, preferredQuality: AudioQuality, preferDolbyAtmos: Bool = false) async -> (url: URL, quality: AudioQuality, isDolbyAtmos: Bool)? {
		// Ask for the Atmos rendition explicitly (`immersiveaudio=true` inside
		// `dolbyAtmosUrl`) before touching the ladder.
		if preferDolbyAtmos, preferredQuality.admitsDolbyAtmos, let atmosUrl = await dolbyAtmosUrl(trackId: trackId) {
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
			if let manifest = await playbackManifestUrl(trackId: trackId, audioQuality: quality, ceiling: preferredQuality) {
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
	/// manifest, while High and Low answer with a DASH manifest AVPlayer cannot play.
	/// `audioQuality` is the tier asked; `ceiling` gates what arrives, so an Atmos answer is
	/// refused when the ceiling does not admit it, exactly as the Atmos request is gated.
	func playbackManifestUrl(trackId: Int, audioQuality: AudioQuality, ceiling: AudioQuality) async -> AcceptedPlaybackManifest? {
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/playbackinfopostpaywall")!
		var parameters = sessionParameters
		parameters["audioquality"] = audioQuality.rawValue
		parameters["playbackmode"] = "STREAM"
		parameters["assetpresentation"] = "FULL"
		do {
			let response: TrackPlaybackInfo = try await get(url: url, parameters: parameters)
			return PlaybackManifestPolicy.accept(response, ceiling: ceiling)
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

extension AudioQuality {
	/// The tier the direct `streamUrl` ladder really serves for a requested tier, so a file
	/// name and a badge describe the bytes rather than the request.
	///
	/// A `HI_RES_LOSSLESS` request is answered with the 16-bit lossless file, byte-identical to
	/// a Lossless request (measured 2026-10-04), so the served tier is never above High; and a
	/// track whose catalogue quality is below the request cannot be served above what it
	/// advertises.
	public func servedByDirectStream(advertised: AudioQuality?) -> AudioQuality {
		var quality: AudioQuality = self == .max ? .high : self
		guard let advertised else { return quality }
		if quality == .high, advertised == .medium || advertised == .low {
			quality = .medium
		}
		if quality == .medium, advertised == .low {
			quality = .low
		}
		return quality
	}
}

extension URL {
	/// A plain-http manifest entry cannot be read where ATS refuses it; `nonisolated` so a
	/// manifest fetch can read it off the main actor.
	nonisolated var upgradedToHTTPS: URL {
		guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
		guard components.scheme?.lowercased() == "http" else { return self }
		components.scheme = "https"
		return components.url ?? self
	}
}
