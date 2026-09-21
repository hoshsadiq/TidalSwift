//
//  ContentUrls.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

extension Session {
	func audioUrl(trackId: Int, audioQuality: AudioQuality) async -> URL? {
		var parameters = sessionParameters
		parameters["soundQuality"] = "\(audioQuality.rawValue)"
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/\(config.urlType.rawValue)")!
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

	public func bestAudioUrl(trackId: Int, preferredQuality: AudioQuality) async -> (url: URL, quality: AudioQuality)? {
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
				return (url, quality)
			}
			// Atmos tracks are refused by `streamUrl`; the manifest endpoint serves them.
			if let url = await playbackManifestUrl(trackId: trackId, audioQuality: quality) {
				bestResolvedAudioQualities[trackId] = quality
				return (url, quality)
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
	/// for tracks `streamUrl`/`offlineUrl` refuse. Dolby Atmos-only tracks answer
	/// HTTP 401 subStatus 4005 "Asset is not ready for playback". Returns nil for
	/// non-BTS manifests: hi-res answers with DASH, which AVPlayer cannot play.
	func playbackManifestUrl(trackId: Int, audioQuality: AudioQuality) async -> URL? {
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/playbackinfopostpaywall")!
		var parameters = sessionParameters
		parameters["audioquality"] = audioQuality.rawValue
		parameters["playbackmode"] = "STREAM"
		parameters["assetpresentation"] = "FULL"
		do {
			let response: TrackPlaybackInfo = try await get(url: url, parameters: parameters)
			guard response.manifestMimeType == "application/vnd.tidal.bts",
				  let data = Data(base64Encoded: response.manifest),
				  let manifest = try? JSONDecoder().decode(BTSManifest.self, from: data) else {
				return nil
			}
			if let encryption = manifest.encryptionType, encryption != "NONE" {
				return nil
			}
			return manifest.urls.first?.upgradedToHTTPS
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

private extension URL {
	var upgradedToHTTPS: URL {
		guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
		guard components.scheme?.lowercased() == "http" else { return self }
		components.scheme = "https"
		return components.url ?? self
	}
}
