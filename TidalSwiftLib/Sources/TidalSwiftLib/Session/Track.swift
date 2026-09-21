//
//  Track.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation

public enum TrackOrder: String {
	case name = "NAME"
	case artist = "ARTIST"
	case album = "ALBUM"
	case dateAdded = "DATE"
	case length = "LENGTH"
}

public enum AudioUrlType: String {
	case streaming = "streamUrl"
	case offline = "offlineUrl"
}

extension Session {
	public func track(trackId: Int) async -> Track? {
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)")!
		do {
			let response: Track = try await get(url: url, parameters: sessionParameters)
			return response
		} catch {
			return nil
		}
	}

	public func trackCredits(trackId: Int) async -> [Credit]? {
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/credits")!
		do {
			let response: [Credit] = try await get(url: url, parameters: sessionParameters)
			return response
		} catch {
			return nil
		}
	}

	// Delete inexistent or unaccessable Tracks from list
	// Detected by checking for nil values
	public func cleanTrackList(_ trackList: [Track]) -> [Track] {
		var result = [Track]()
		for track in trackList {
			if !(track.streamStartDate == nil || track.audioQuality == nil) {
				result.append(track)
			}
		}
		return result
	}

	public func trackRadio(trackId: Int, limit: Int = 100, offset: Int = 0) async -> [Track]? {
		var parameters = sessionParameters
		parameters["limit"] = "\(limit)"
		parameters["offset"] = "\(offset)"

		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/radio")!
		do {
			let response: Tracks = try await get(url: url, parameters: parameters)
			return response.items
		} catch {
			return nil
		}
	}

	public func trackMix(trackId: Int) async -> String? {
		let url = URL(string: "\(AuthInformation.APILocation)/tracks/\(trackId)/mix")!
		do {
			let response: MixIdResponse = try await get(url: url, parameters: sessionParameters)
			return response.id
		} catch {
			return nil
		}
	}

	/// Suggested tracks for a track.
	///
	/// T1 recon found that `/tracks/{id}/similar` does not exist (404 on every
	/// variant), so this wraps the verified `/tracks/{id}/radio` endpoint.
	public func trackSimilar(trackId: Int) async -> [Track]? {
		await trackRadio(trackId: trackId)
	}

	/// The "Mixes & Radio" cards for a track: Track Radio and Artist Radio.
	///
	/// Built from verified endpoints only. The mix ids are the real ones from
	/// `/tracks/{id}/mix` and `/artists/{id}/mix`, so `MixGridItem`'s existing
	/// click actions (push the mix view / play the mix) keep working. The card
	/// artwork is a collage of the first radio tracks' covers.
	public func trackMixesRadio(trackId: Int) async -> [MixesItem]? {
		guard let track = await track(trackId: trackId) else { return nil }
		guard let artist = track.artists.first else { return nil }

		async let trackRadioTracks = trackRadio(trackId: trackId)
		async let artistRadioTracks = artistRadio(artistId: artist.id)
		async let trackMixId = trackMix(trackId: trackId)
		async let artistMixId = artistMix(artistId: artist.id)

		let (radioTracks, artistTracks, trackMix, artistMix) =
			await (trackRadioTracks, artistRadioTracks, trackMixId, artistMixId)

		var mixes: [MixesItem] = []
		if let trackMix, let radioTracks, !radioTracks.isEmpty {
			mixes.append(MixesItem(
				id: trackMix,
				title: "Track Radio",
				subTitle: track.title,
				graphic: Self.radioGraphic(from: radioTracks),
				images: nil,
				mixType: .track
			))
		}
		if let artistMix, let artistTracks, !artistTracks.isEmpty {
			mixes.append(MixesItem(
				id: artistMix,
				title: "Artist Radio",
				subTitle: artist.name,
				graphic: Self.radioGraphic(from: artistTracks),
				images: nil,
				mixType: .artist
			))
		}
		return mixes.isEmpty ? nil : mixes
	}

	/// A `MixImage`-style collage from the first radio tracks' album covers.
	/// `MixImage` only renders the collage when there are at least five images.
	private static func radioGraphic(from tracks: [Track]) -> MixesGraphic? {
		let images = tracks.prefix(5).compactMap { track -> MixesGraphicImage? in
			guard let cover = track.album.cover else { return nil }
			return MixesGraphicImage(id: cover, vibrantColor: "8E8E93", type: .artist)
		}
		guard images.count >= 5 else { return nil }
		return MixesGraphic(type: .squaresGrid, text: "", images: images)
	}
}
