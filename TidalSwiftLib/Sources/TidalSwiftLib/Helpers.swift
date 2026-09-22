//
//  Helpers.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 23.05.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation
import Combine

public class Helpers {
	unowned let session: Session
	private let metadata: Metadata
	public let downloadStatus = DownloadStatus()
	public let offline: Offline
	public let download: Download

	public init(session: Session) {
		self.session = session
		self.metadata = Metadata(session: session)
		self.offline = Offline(session: session, downloadStatus: downloadStatus)
		self.download = Download(session: session, metadata: self.metadata, downloadStatus: downloadStatus)
	}

	/// The newest albums of the user's favourite artists.
	///
	/// Fetches every favourite artist's albums (plus EPs and singles when
	/// `includeEps`), merges them, collapses the per-variant copies TIDAL lists
	/// (see `collapseVariants`), sorts newest-first and keeps the first
	/// `number`. `maxQuality` is the playback quality from the user's settings;
	/// it caps which copy of a release is preferred. Returns `nil` only when the
	/// favourite-artists call fails; an account without favourite artists yields
	/// an empty array.
	public func newReleasesFromFavouriteArtists(
		number: Int = 40,
		includeEps: Bool = true,
		maxQuality: AudioQuality? = nil
	) async -> [Album]? {
		guard let favouriteArtists = await session.favorites?.artists() else {
			return nil
		}

		// A favourites list can hold hundreds of artists, so fetch in small
		// batches instead of firing every request at once — the API rate-limits.
		var allReleases: [Album] = []
		let batchSize = 4
		for batchStart in stride(from: 0, to: favouriteArtists.count, by: batchSize) {
			guard !Task.isCancelled else { break }
			let batch = favouriteArtists[batchStart ..< min(batchStart + batchSize, favouriteArtists.count)]
			let batchReleases = await withTaskGroup(of: [Album]?.self, returning: [Album].self) { [session] group in
				for artist in batch {
					group.addTask { await session.artistAlbums(artistId: artist.item.id, filter: nil, limit: number) }
					if includeEps {
						group.addTask { await session.artistAlbums(artistId: artist.item.id, filter: .epsAndSingles, limit: number) }
					}
				}

				var releases: [Album] = []
				for await albums in group {
					guard let albums else { continue }
					releases.append(contentsOf: albums)
				}
				return releases
			}
			allReleases.append(contentsOf: batchReleases)
		}

		return Self.newestFirst(Self.collapseVariants(allReleases, maxQuality: maxQuality), number: number)
	}

	/// Keeps one entry per release.
	///
	/// TIDAL lists one entry per variant — explicit or clean × quality tier — so
	/// the same single can turn up six times with an identical title, artist and
	/// release date. Preference order: a Dolby Atmos copy first, then the best
	/// quality at or below `maxQuality` (the user's setting; anything above it is
	/// never preferred), explicit before clean within a tier, then the lowest
	/// album id so the row stays stable between refreshes.
	///
	/// TODO: Follow the "Allow explicit content" setting (Preferences → General)
	/// once it exists instead of always preferring the explicit copy.
	static func collapseVariants(_ albums: [Album], maxQuality: AudioQuality?) -> [Album] {
		var best: [String: Album] = [:]
		for album in albums {
			let key = [
				album.title,
				album.artist?.name ?? "",
				album.releaseDate.map { String($0.timeIntervalSince1970) } ?? "",
				album.version ?? ""
			].joined(separator: "|")
			guard let current = best[key] else {
				best[key] = album
				continue
			}
			let rank = variantRank(album, maxQuality: maxQuality)
			let currentRank = variantRank(current, maxQuality: maxQuality)
			if rank > currentRank || (rank == currentRank && album.id < current.id) {
				best[key] = album
			}
		}
		return Array(best.values)
	}

	private static func variantRank(_ album: Album, maxQuality: AudioQuality?) -> Int {
		let tier = qualityTier(album.audioQuality)
		let isAtmos = album.audioModes?.contains(.dolbyAtmos) ?? false
		let withinCap = isAtmos || tier <= qualityTier(maxQuality ?? .max)
		let bestTier = isAtmos ? 5 : tier
		return (withinCap ? 100 : 0) + bestTier * 10 + (album.explicit == true ? 1 : 0)
	}

	private static func qualityTier(_ quality: AudioQuality?) -> Int {
		switch quality {
		case .max:
			return 4
		case .high:
			return 3
		case .medium:
			return 2
		case .low:
			return 1
		default:
			return 0
		}
	}

	/// Merges `albums` into a set (deduplicating by id), sorts them by
	/// `releaseDate` descending with `nil` dates last, and keeps the first
	/// `number`.
	static func newestFirst(_ albums: [Album], number: Int) -> [Album] {
		let unique = Set(albums)
		let sorted = unique.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
		return Array(sorted.prefix(number))
	}
}
