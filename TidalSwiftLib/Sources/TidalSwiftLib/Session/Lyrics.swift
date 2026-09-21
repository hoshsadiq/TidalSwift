//
//  Lyrics.swift
//  TidalSwiftLib
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import Foundation
import os

let lyricsLogger = Logger(subsystem: "de.melgu.TidalSwift", category: "lyrics")

/// Lyrics as returned by Tidal's v2 catalog API.
public struct TidalLyrics: Equatable {
	/// LRC-timestamped lyrics (`attributes.lrcText`), when present.
	public let lrc: String?
	/// Plain, untimed lyrics (`attributes.text`), when present.
	public let plain: String?

	public init(lrc: String?, plain: String?) {
		self.lrc = lrc
		self.plain = plain
	}
}

/// Lyrics as returned by LRCLIB.
public struct LRCLIBLyrics: Equatable {
	/// LRC-timestamped lyrics (`syncedLyrics`), when present.
	public let lrc: String?
	/// Plain, untimed lyrics (`plainLyrics`), when present.
	public let plain: String?

	public init(lrc: String?, plain: String?) {
		self.lrc = lrc
		self.plain = plain
	}
}

extension String {
	/// `self` when it contains anything but whitespace, `nil` otherwise.
	var nonEmpty: String? {
		trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
	}
}

// MARK: - Tidal v2

/// JSON:API envelope of `GET /tracks/{id}?include=lyrics`.
struct TrackLyricsResponse: Decodable {
	struct Resource: Decodable {
		let type: String
		let attributes: TrackLyricsAttributes?
	}

	let included: [Resource]?
}

struct TrackLyricsAttributes: Decodable {
	let lrcText: String?
	let text: String?
	let technicalStatus: String?
}

extension Session {
	/// Fetches lyrics for a track from Tidal's v2 catalog API
	/// (`openapi.tidal.com/v2/tracks/{id}?include=lyrics`).
	///
	/// Returns `nil` when the track has no lyrics resource, when the resource's
	/// `technicalStatus` isn't `OK`, or when the request fails. A track without
	/// lyrics answers HTTP 200 with an empty `included` array.
	public func trackLyrics(trackId: Int) async -> TidalLyrics? {
		guard let url = URL(string: "\(AuthInformation.APIV2OpenAPILocation)/tracks/\(trackId)") else {
			return nil
		}
		var parameters = sessionParameters
		parameters.removeValue(forKey: "limit")
		parameters["include"] = "lyrics"
		do {
			let response: TrackLyricsResponse = try await v2Get(url: url, parameters: parameters)
			guard let resource = response.included?.first(where: { $0.type == "lyrics" }),
				  resource.attributes?.technicalStatus == "OK" else {
				lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) none")
				return nil
			}
			let lrc = resource.attributes?.lrcText?.nonEmpty
			let plain = resource.attributes?.text?.nonEmpty
			guard lrc != nil || plain != nil else {
				lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) empty")
				return nil
			}
			lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) lrc=\(lrc != nil, privacy: .public) plain=\(plain != nil, privacy: .public)")
			return TidalLyrics(lrc: lrc, plain: plain)
		} catch {
			lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) failed")
			return nil
		}
	}
}

// MARK: - LRCLIB

/// A record from LRCLIB's `/api/get` or `/api/search`.
struct LRCLIBRecord: Decodable {
	let duration: Double?
	let instrumental: Bool?
	let plainLyrics: String?
	let syncedLyrics: String?

	/// The usable lyrics of this record, or `nil` for instrumentals and records
	/// without any lyrics text.
	var lyrics: LRCLIBLyrics? {
		guard instrumental != true else { return nil }
		let lrc = syncedLyrics?.nonEmpty
		let plain = plainLyrics?.nonEmpty
		guard lrc != nil || plain != nil else { return nil }
		return LRCLIBLyrics(lrc: lrc, plain: plain)
	}
}

/// LRCLIB's error body, e.g. `{"message":"Failed to find specified track","name":"TrackNotFound","statusCode":404}`.
nonisolated struct LRCLIBError: Decodable {
	let message: String
	let name: String
	let statusCode: Int
}

/// Outcome of a single LRCLIB HTTP request.
enum LRCLIBResponse {
	case success(Data)
	case notFound
	case rateLimited
	case failure

	var logDescription: String {
		switch self {
		case .success:
			"200"
		case .notFound:
			"404"
		case .rateLimited:
			"429"
		case .failure:
			"failed"
		}
	}
}

/// Serialises LRCLIB requests and enforces the documented 200–500 ms gap.
///
/// LRCLIB asks clients to send requests sequentially with a short gap; rapid
/// parallel calls get `503 ServerOverloaded` (observed during recon). Each
/// `perform` waits for the previous one to finish plus the gap.
actor LRCLIBThrottle {
	static let shared = LRCLIBThrottle()

	/// Mid-point of the documented 200–500 ms range.
	private static let gap: Duration = .milliseconds(350)

	private var previous: Task<Void, Never>?

	func perform<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
		let previous = self.previous
		let task = Task {
			if let previous {
				await previous.value
				try? await Task.sleep(for: Self.gap)
			}
			return await operation()
		}
		self.previous = Task { _ = await task.value }
		return await task.value
	}
}

extension Session {
	/// Fetches lyrics from LRCLIB (`lrclib.net`).
	///
	/// Tries `/api/get` with the exact metadata first; on a miss (HTTP 404)
	/// falls back to `/api/search` and picks the closest-duration match.
	/// Requests are serialised with a 200–500 ms gap and honour `429` +
	/// `Retry-After`. Returns `nil` when nothing usable is found.
	public func lrclibLyrics(
		trackName: String,
		artistName: String,
		albumName: String,
		duration: Int
	) async -> LRCLIBLyrics? {
		let getParameters = [
			"track_name": trackName,
			"artist_name": artistName,
			"album_name": albumName,
			"duration": String(duration)
		]
		switch await lrclibRequest(path: "api/get", parameters: getParameters) {
		case .success(let data):
			guard let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) else { return nil }
			return record.lyrics
		case .notFound:
			break
		case .rateLimited, .failure:
			return nil
		}

		let searchParameters = ["track_name": trackName, "artist_name": artistName]
		guard case .success(let data) = await lrclibRequest(path: "api/search", parameters: searchParameters),
			  let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) else {
			return nil
		}
		return Self.bestLRCLIBMatch(in: records, duration: duration)?.lyrics
	}

	/// Picks the closest-duration record, preferring ones with synced lyrics.
	static func bestLRCLIBMatch(in records: [LRCLIBRecord], duration: Int) -> LRCLIBRecord? {
		let candidates = records.filter { $0.lyrics != nil }
		guard !candidates.isEmpty else { return nil }
		return candidates.min { lhs, rhs in
			let lhsSynced = lhs.syncedLyrics?.nonEmpty != nil
			let rhsSynced = rhs.syncedLyrics?.nonEmpty != nil
			if lhsSynced != rhsSynced { return lhsSynced }
			return abs((lhs.duration ?? 0) - Double(duration)) < abs((rhs.duration ?? 0) - Double(duration))
		}
	}

	private func lrclibRequest(path: String, parameters: [String: String]) async -> LRCLIBResponse {
		guard var components = URLComponents(string: "\(AuthInformation.LRCLIBLocation)/\(path)") else {
			return .failure
		}
		components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
		guard let url = components.url else { return .failure }

		lyricsLogger.debug("lrclib request path=\(path, privacy: .public)")
		let userAgent = AuthInformation.safariUserAgent
		let logger = lyricsLogger
		let response = await LRCLIBThrottle.shared.perform {
			for attempt in 0..<2 {
				var request = URLRequest(url: url)
				request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
				request.setValue("application/json", forHTTPHeaderField: "Accept")
				guard let (data, http) = try? await URLSession.shared.data(for: request),
					  let http = http as? HTTPURLResponse else {
					return LRCLIBResponse.failure
				}
				switch http.statusCode {
				case 200:
					return .success(data)
				case 404:
					if let error = try? JSONDecoder().decode(LRCLIBError.self, from: data) {
						logger.debug("lrclib miss path=\(path, privacy: .public) name=\(error.name, privacy: .public)")
					}
					return .notFound
				case 429:
					guard attempt == 0 else { return .rateLimited }
					try? await Task.sleep(for: Self.retryAfter(from: http))
				default:
					return .failure
				}
			}
			return .rateLimited
		}
		lyricsLogger.debug("lrclib response path=\(path, privacy: .public) status=\(response.logDescription, privacy: .public)")
		return response
	}

	/// `Retry-After` in seconds, capped so a misbehaving server can't stall the
	/// fetch indefinitely. Defaults to 1 s when the header is missing or unparsable.
	private static func retryAfter(from response: HTTPURLResponse) -> Duration {
		let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
		return .seconds(min(max(seconds, 0), 30))
	}
}
