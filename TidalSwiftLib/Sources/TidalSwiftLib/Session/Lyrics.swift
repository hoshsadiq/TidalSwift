//
//  Lyrics.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import os

let lyricsLogger = Logger(subsystem: "io.hosh.TidalSwift", category: "lyrics")

/// What a lyrics provider, or the resolver reading both, answered.
///
/// A failure is kept apart from a genuine miss: one means the answer is unknown,
/// the other means there is nothing to show.
public enum LyricsOutcome<Value: Equatable>: Equatable {
	case found(Value)
	case notFound
	case failed

	/// The provider's lyrics, `nil` for both a miss and a failure.
	public var value: Value? {
		guard case .found(let value) = self else { return nil }
		return value
	}

	/// Whether the provider could not answer, as opposed to answering "nothing".
	public var isFailure: Bool {
		if case .failed = self { return true }
		return false
	}
}

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

// `nonisolated` because the file readers ask the same question off the main actor.
nonisolated extension String {
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
	/// Returns `.notFound` when the track has no lyrics resource or the
	/// resource's `technicalStatus` isn't `OK`, and `.failed` when the request
	/// itself fails. A track without lyrics answers HTTP 200 with an empty
	/// `included` array.
	///
	/// The status is read before the body is trusted. An error page decodes to nothing, so
	/// decoding first would report a Tidal outage as "no lyrics" and leave the caller no
	/// reason to ask again.
	public func trackLyrics(trackId: Int) async -> LyricsOutcome<TidalLyrics> {
		guard let url = URL(string: "\(AuthInformation.APIV2OpenAPILocation)/tracks/\(trackId)") else {
			return .failed
		}
		var parameters = sessionParameters
		parameters.removeValue(forKey: "limit")
		parameters["include"] = "lyrics"
		do {
			let http = try await v2GetResponse(url: url, parameters: parameters)
			let status = http.statusCode ?? 0
			// A 404 is the API saying the track is not there: an answer, not a fault, and it
			// stays one whatever the body holds. Decoding first would turn an empty 404 body
			// into a throw and so into a failure worth retrying.
			if status == 404 {
				lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) not found")
				return .notFound
			}
			guard (200..<300).contains(status) else {
				lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) status=\(status, privacy: .public) failed")
				return .failed
			}
			let response = try JSONDecoder.custom.decode(TrackLyricsResponse.self, from: http.data)
			guard let resource = response.included?.first(where: { $0.type == "lyrics" }),
				  resource.attributes?.technicalStatus == "OK" else {
				lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) none")
				return .notFound
			}
			let lrc = resource.attributes?.lrcText?.nonEmpty
			let plain = resource.attributes?.text?.nonEmpty
			guard lrc != nil || plain != nil else {
				lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) empty")
				return .notFound
			}
			lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) lrc=\(lrc != nil, privacy: .public) plain=\(plain != nil, privacy: .public)")
			return .found(TidalLyrics(lrc: lrc, plain: plain))
		} catch {
			lyricsLogger.debug("tidal lyrics track=\(trackId, privacy: .public) failed")
			return .failed
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
nonisolated enum LRCLIBResponse {
	case success(Data)
	case notFound
	/// Too many requests, carrying the wait the server asked for.
	case rateLimited(after: Duration)
	case failure(statusCode: Int?)

	var logDescription: String {
		switch self {
		case .success:
			"200"
		case .notFound:
			"404"
		case .rateLimited:
			"429"
		case .failure(let statusCode):
			statusCode.map(String.init) ?? "transport"
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
	/// No request may go out before this instant. Set when LRCLIB states a wait, so a
	/// caller that asks again sooner than the server allowed (the lyrics panel after a
	/// failure) still cannot send early. Shared, because the wait belongs to the host
	/// rather than to whichever surface provoked it.
	private var quietUntil: ContinuousClock.Instant?

	/// Records a wait the provider asked for, keeping the longest one already known.
	func quiet(for wait: Duration) {
		let until = ContinuousClock.now.advanced(by: wait)
		if let quietUntil, quietUntil > until {
			return
		}
		quietUntil = until
	}

	/// Runs `operation` once the previous request is done, the documented gap has passed and
	/// any stated wait has elapsed. `nil` when the caller was cancelled before its request
	/// went out: that surface is gone, and a queued request per closed panel is one too many.
	func perform<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T? {
		let previous = self.previous
		let task = Task { () -> T? in
			if let previous {
				await previous.value
				try? await Task.sleep(for: Self.gap)
			}
			// Read on arrival rather than on entry: a caller that queued before the wait was
			// recorded must still see it, or the second surface sends early after all.
			if let quietUntil = self.quietUntil {
				let remaining = ContinuousClock.now.duration(to: quietUntil)
				if remaining > .zero {
					try? await Task.sleep(for: remaining)
				}
			}
			guard !Task.isCancelled else { return nil }
			return await operation()
		}
		self.previous = Task { _ = await task.value }
		return await withTaskCancellationHandler {
			await task.value
		} onCancel: {
			task.cancel()
		}
	}
}

extension Session {
	/// Fetches lyrics from LRCLIB (`lrclib.net`).
	///
	/// Tries `/api/get` with the exact metadata first; on a miss (HTTP 404)
	/// falls back to `/api/search` and picks the closest-duration match.
	/// Requests are serialised with a 200–500 ms gap, honour `429` +
	/// `Retry-After`, and make one further attempt after a transient failure.
	/// Returns `.notFound` only when LRCLIB answered that it has nothing.
	public func lrclibLyrics(
		trackName: String,
		artistName: String,
		albumName: String,
		duration: Int
	) async -> LyricsOutcome<LRCLIBLyrics> {
		let getParameters = [
			"track_name": trackName,
			"artist_name": artistName,
			"album_name": albumName,
			"duration": String(duration)
		]
		switch await lrclibRequest(path: "api/get", parameters: getParameters) {
		case .success(let data):
			return Self.lyrics(fromRecordData: data)
		case .notFound:
			// A panel the user has left must not spend a second request on the search.
			guard !Task.isCancelled else { return .failed }
			return await search(trackName: trackName, artistName: artistName, duration: duration)
		case .rateLimited, .failure:
			return .failed
		}
	}

	/// The `/api/get` leg's payload, mapped to a fetch outcome. A 200 is final:
	/// an instrumental or lyric-less record is LRCLIB's answer, not a reason to
	/// search for a different version.
	private static func lyrics(fromRecordData data: Data) -> LyricsOutcome<LRCLIBLyrics> {
		// An unreadable body is a fault, not an answer, so the caller is told to ask again
		// rather than shown an empty panel.
		guard let record = try? JSONDecoder().decode(LRCLIBRecord.self, from: data) else { return .failed }
		guard let lyrics = record.lyrics else { return .notFound }
		return .found(lyrics)
	}

	/// The `/api/search` fallback for a track `/api/get` does not know.
	private func search(
		trackName: String,
		artistName: String,
		duration: Int
	) async -> LyricsOutcome<LRCLIBLyrics> {
		let parameters = ["track_name": trackName, "artist_name": artistName]
		switch await lrclibRequest(path: "api/search", parameters: parameters) {
		case .success(let data):
			guard let records = try? JSONDecoder().decode([LRCLIBRecord].self, from: data) else { return .failed }
			guard let match = Self.bestLRCLIBMatch(in: records, duration: duration)?.lyrics else { return .notFound }
			return .found(match)
		case .notFound:
			return .notFound
		case .rateLimited, .failure:
			return .failed
		}
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
			return .failure(statusCode: nil)
		}
		components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
		guard let url = components.url else { return .failure(statusCode: nil) }

		lyricsLogger.debug("lrclib request path=\(path, privacy: .public)")
		let userAgent = AuthInformation.safariUserAgent
		let logger = lyricsLogger
		// Read on this actor before the fetch moves to the throttle's own task.
		let httpSession = requestSession
		let response = await LRCLIBThrottle.shared.perform {
			var attempts = 1
			while true {
				var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
				request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
				request.setValue("application/json", forHTTPHeaderField: "Accept")
				let outcome = await Self.lrclibAttempt(request, path: path, logger: logger, httpSession: httpSession)
				guard attempts < Self.maxAttempts, let delay = Self.retryDelay(for: outcome) else {
					return outcome
				}
				attempts += 1
				try? await Task.sleep(for: delay)
			}
		} ?? .failure(statusCode: nil)
		// Still rate-limited once this request gave up: hold the whole chain for the wait the
		// server stated, or the lyrics panel's outer schedule asks again within seconds and
		// each ask pays that wait again behind the shared throttle.
		if case .rateLimited(let wait) = response {
			await LRCLIBThrottle.shared.quiet(for: wait)
		}
		lyricsLogger.debug("lrclib response path=\(path, privacy: .public) status=\(response.logDescription, privacy: .public)")
		return response
	}

	/// Attempts per request, and the gap before the second one after a transient
	/// failure. Both stay small: LRCLIB is a free service, and a lyrics panel is
	/// not worth a long backoff.
	private nonisolated static let maxAttempts = 2
	private nonisolated static let transientRetryDelay: Duration = .milliseconds(500)

	/// Never retry sooner than the low end of the gap `LRCLIBThrottle` paces requests
	/// with, and never hold the shared throttle for a stalled request for long.
	private nonisolated static let minimumRetryGap: Double = 0.2
	private nonisolated static let requestTimeout: TimeInterval = 10

	/// One LRCLIB request, no retry.
	private nonisolated static func lrclibAttempt(
		_ request: URLRequest,
		path: String,
		logger: Logger,
		httpSession: URLSession
	) async -> LRCLIBResponse {
		guard let (data, response) = try? await httpSession.data(for: request),
			  let http = response as? HTTPURLResponse else {
			return .failure(statusCode: nil)
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
			return .rateLimited(after: retryAfter(from: http))
		default:
			return .failure(statusCode: http.statusCode)
		}
	}

	/// The wait before a second attempt, or `nil` when a second attempt would get
	/// the same answer.
	///
	/// A 429 states its own wait. A 5xx or a transport failure is a blip worth one
	/// more ask. Any other status is a refusal.
	nonisolated static func retryDelay(for outcome: LRCLIBResponse) -> Duration? {
		switch outcome {
		case .rateLimited(let stated):
			return stated
		case .failure(let statusCode):
			guard let statusCode else { return transientRetryDelay }
			return statusCode == 408 || statusCode >= 500 ? transientRetryDelay : nil
		case .success, .notFound:
			return nil
		}
	}

	/// `Retry-After` in seconds, bounded at both ends so a misbehaving server can
	/// neither trap the fetch on a non-finite value nor stall it indefinitely.
	/// Missing or unparsable headers mean one second.
	nonisolated static func retryAfter(from response: HTTPURLResponse) -> Duration {
		let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1
		guard seconds.isFinite else { return .seconds(1) }
		return .seconds(min(max(seconds, minimumRetryGap), 30))
	}
}
