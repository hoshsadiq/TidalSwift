//
//  DashAudio.swift
//  TidalSwiftLib
//

import AVFoundation
import Foundation

/// Why a DASH audio manifest could not be read or assembled. Every case is a refusal:
/// a DASH source either produces a complete, playable file or fails loudly.
public nonisolated enum DashAudioError: Error, Equatable, Sendable {
	case malformedManifest
	case missingSegmentTemplate
	case missingInitializationURL
	case missingMediaTemplate
	case unsupportedSegmentTemplate
	case missingSegmentTimeline
	/// Only the host is kept, since a segment URL carries its own token.
	case fetchFailed(host: String)
	case writeFailed(underlying: Error)

	public static func == (lhs: DashAudioError, rhs: DashAudioError) -> Bool {
		switch (lhs, rhs) {
		case (.malformedManifest, .malformedManifest),
			(.missingSegmentTemplate, .missingSegmentTemplate),
			(.missingInitializationURL, .missingInitializationURL),
			(.missingMediaTemplate, .missingMediaTemplate),
			(.unsupportedSegmentTemplate, .unsupportedSegmentTemplate),
			(.missingSegmentTimeline, .missingSegmentTimeline):
			return true
		case (.fetchFailed(let l), .fetchFailed(let r)):
			return l == r
		case (.writeFailed, .writeFailed):
			return true
		default:
			return false
		}
	}
}

/// A parsed `SegmentTemplate`-based DASH audio manifest. Tidal's High/Low
/// `playbackinfo` answers with one of these: an `audio/mp4` AAC representation whose
/// segments are plain, unencrypted fMP4, in the attribute form Tidal ships.
public nonisolated struct DashAudioManifest: Equatable, Sendable {
	public let initializationURL: URL
	public let mediaTemplate: String
	public let startNumber: Int
	public let segmentCount: Int
	public let timescale: Int?

	public init(initializationURL: URL, mediaTemplate: String, startNumber: Int, segmentCount: Int, timescale: Int?) {
		self.initializationURL = initializationURL
		self.mediaTemplate = mediaTemplate
		self.startNumber = startNumber
		self.segmentCount = segmentCount
		self.timescale = timescale
	}

	/// Parses the base64 MPD body of an `application/dash+xml` manifest.
	public init(base64Manifest: String) throws {
		guard let data = Data(base64Encoded: base64Manifest) else {
			throw DashAudioError.malformedManifest
		}
		try self.init(mpd: data)
	}

	public init(mpd: Data) throws {
		let delegate = DashMPDParserDelegate()
		let parser = XMLParser(data: mpd)
		parser.delegate = delegate
		guard parser.parse() else { throw DashAudioError.malformedManifest }
		// A document can carry audio and video adaptation sets; prefer an audio one.
		guard let template = delegate.templates.first(where: { $0.isAudio }) ?? delegate.templates.first else {
			throw DashAudioError.missingSegmentTemplate
		}
		guard let media = template.attributes["media"] else { throw DashAudioError.missingMediaTemplate }
		guard media.contains("$Number$") else { throw DashAudioError.unsupportedSegmentTemplate }
		guard let initialization = template.attributes["initialization"],
			  let initializationURL = URL(string: initialization) else {
			throw DashAudioError.missingInitializationURL
		}
		guard !template.repeats.isEmpty else { throw DashAudioError.missingSegmentTimeline }

		// `r` is a repeat count: each `<S>` covers 1 + r segments.
		self.initializationURL = initializationURL.upgradedToHTTPS
		self.mediaTemplate = media
		self.startNumber = Int(template.attributes["startNumber"] ?? "1") ?? 1
		self.segmentCount = template.repeats.reduce(0) { $0 + 1 + $1 }
		self.timescale = template.attributes["timescale"].flatMap(Int.init)
	}

	public func mediaURL(forNumber number: Int) -> URL? {
		URL(string: mediaTemplate.replacingOccurrences(of: "$Number$", with: String(number)))?.upgradedToHTTPS
	}
}

/// Reads an `<SegmentTemplate>` element out of an MPD, kept separate so the parse can be tested alone.
private nonisolated final class DashMPDParserDelegate: NSObject, XMLParserDelegate {
	struct Template {
		let attributes: [String: String]
		let repeats: [Int]
		let isAudio: Bool
	}

	private(set) var templates: [Template] = []
	private var currentTemplate: (attributes: [String: String], repeats: [Int])?
	private var adaptationSetIsAudio = false

	func parser(
		_ parser: XMLParser,
		didStartElement elementName: String,
		namespaceURI: String?,
		qualifiedName qName: String?,
		attributes attributeDict: [String: String]
	) {
		switch elementName {
		case "AdaptationSet":
			let contentType = attributeDict["contentType"] ?? ""
			let mimeType = attributeDict["mimeType"] ?? ""
			adaptationSetIsAudio = contentType == "audio" || mimeType.hasPrefix("audio/")
		case "SegmentTemplate":
			currentTemplate = (attributeDict, [])
		case "S":
			// `r` is optional and means "this duration repeats r more times".
			currentTemplate?.repeats.append(Int(attributeDict["r"] ?? "0") ?? 0)
		default:
			break
		}
	}

	func parser(
		_ parser: XMLParser,
		didEndElement elementName: String,
		namespaceURI: String?,
		qualifiedName qName: String?
	) {
		guard elementName == "SegmentTemplate", let template = currentTemplate else { return }
		templates.append(Template(attributes: template.attributes, repeats: template.repeats, isAudio: adaptationSetIsAudio))
		currentTemplate = nil
	}
}

/// Fetches and assembles the media segments of a DASH audio manifest into one file.
public nonisolated enum DashAudio {
	/// Fetches one resource. The default reads `file://` URLs directly, `URLSession`
	/// otherwise; tests substitute a closure so no network is needed.
	public typealias SegmentFetcher = @Sendable (URL) async throws -> Data

	/// Segments fetched at once; four keeps the small requests from stalling each other.
	static let maxConcurrentFetches = 4
	/// A transient CDN failure is retried, a persistent one is reported not truncated.
	static let maxFetchAttempts = 3
	static let retryBackoff: [Duration] = [.milliseconds(200), .milliseconds(400)]
	/// The longest one segment may take, retries and backoff included, so a stalled CDN
	/// cannot hold an assembly for minutes.
	static let segmentFetchTimeout: Duration = .seconds(30)

	/// Downloads every segment and writes them to `destination` in order.
	public static func assemble(_ manifest: DashAudioManifest, to destination: URL) async throws {
		// The desktop identity lives on the main actor and a track has around 30
		// segments, so it is read once here.
		let userAgent = await MainActor.run { AuthInformation.tidalClientUserAgent }
		try await assemble(manifest, to: destination, fetch: defaultFetch(userAgent: userAgent))
	}

	/// Downloads the initialization segment plus every media segment and writes them
	/// to `destination` in order. Nothing is written until every segment has been
	/// fetched, so a failure leaves no output file at all.
	///
	/// `@concurrent` because the concatenation and the atomic write are synchronous
	/// file IO and every call site is main-actor.
	@concurrent
	public static func assemble(
		_ manifest: DashAudioManifest,
		to destination: URL,
		fetch: @escaping SegmentFetcher
	) async throws {
		try await assemble(manifest, to: destination, fetch: fetch, timeout: segmentFetchTimeout)
	}

	/// As above, with the fetch bound exposed so a test can shrink it.
	@concurrent
	static func assemble(
		_ manifest: DashAudioManifest,
		to destination: URL,
		fetch: @escaping SegmentFetcher,
		timeout: Duration
	) async throws {
		let initialization = try await fetchWithRetry(manifest.initializationURL, fetch: fetch, timeout: timeout)
		let numbers = (manifest.startNumber ..< manifest.startNumber + manifest.segmentCount).map { $0 }
		let segments = try await fetchSegments(numbers: numbers, manifest: manifest, fetch: fetch, timeout: timeout)

		var file = Data()
		file.reserveCapacity(initialization.count + segments.reduce(0) { $0 + $1.count })
		file.append(initialization)
		for segment in segments {
			file.append(segment)
		}
		do {
			try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
			try file.write(to: destination, options: .atomic)
		} catch {
			throw DashAudioError.writeFailed(underlying: error)
		}
	}

	/// The error for a resource that could not be fetched; only the host survives.
	static func fetchFailure(for url: URL) -> DashAudioError {
		DashAudioError.fetchFailed(host: url.host ?? "unknown")
	}

	/// The default fetcher: a local read for `file://`, a plain GET presenting
	/// `userAgent` otherwise. The CDN segment URLs carry their own token and need no
	/// auth header.
	static func defaultFetch(userAgent: String) -> SegmentFetcher {
		{ url in
			if url.isFileURL {
				return try Data(contentsOf: url)
			}
			var request = URLRequest(url: url)
			request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
			let (data, response) = try await URLSession.shared.data(for: request)
			if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
				throw DashAudio.fetchFailure(for: url)
			}
			return data
		}
	}

	/// Fetches the segments in bounded batches, preserving order.
	private static func fetchSegments(
		numbers: [Int],
		manifest: DashAudioManifest,
		fetch: @escaping SegmentFetcher,
		timeout: Duration
	) async throws -> [Data] {
		guard let first = numbers.first, let last = numbers.last,
			  (manifest.startNumber ... manifest.startNumber + manifest.segmentCount).contains(first),
			  (manifest.startNumber ... manifest.startNumber + manifest.segmentCount).contains(last) else {
			throw DashAudioError.unsupportedSegmentTemplate
		}
		var results = [Data?](repeating: nil, count: numbers.count)
		var batchStart = 0
		while batchStart < numbers.count {
			// A cancelled assembly stops between batches rather than starting the next.
			try Task.checkCancellation()
			let batchEnd = min(batchStart + maxConcurrentFetches, numbers.count)
			let batch = batchStart ..< batchEnd
			try await withThrowingTaskGroup(of: (Int, Data).self) { group in
				for index in batch {
					guard let url = manifest.mediaURL(forNumber: numbers[index]) else {
						throw DashAudioError.unsupportedSegmentTemplate
					}
					group.addTask { (index, try await fetchWithRetry(url, fetch: fetch, timeout: timeout)) }
				}
				// Collected by index, so the group's completion order never reorders them.
				for try await (index, data) in group {
					results[index] = data
				}
			}
			batchStart = batchEnd
		}
		return try results.map { data in
			guard let data else { throw DashAudioError.unsupportedSegmentTemplate }
			return data
		}
	}

	/// Fetches `url`, retrying a transient failure while `timeout` has not passed.
	/// Cancellation is propagated, not retried.
	private static func fetchWithRetry(_ url: URL, fetch: @escaping SegmentFetcher, timeout: Duration) async throws -> Data {
		let deadline = ContinuousClock.now.advanced(by: timeout)
		var lastError: Error = DashAudio.fetchFailure(for: url)
		for attempt in 0 ..< maxFetchAttempts {
			try Task.checkCancellation()
			guard ContinuousClock.now < deadline else { throw lastError }
			do {
				return try await fetchBefore(deadline, url: url, fetch: fetch)
			} catch let error as CancellationError {
				throw error
			} catch let error as URLError where error.code == .cancelled {
				throw error
			} catch {
				lastError = error
				if attempt < retryBackoff.count {
					try await Task.sleep(for: retryBackoff[attempt])
				}
			}
		}
		throw lastError
	}

	/// Fetches one segment and fails it when `deadline` passes first. The loser of the
	/// race is cancelled, which also ends an in-flight request.
	private static func fetchBefore(
		_ deadline: ContinuousClock.Instant,
		url: URL,
		fetch: @escaping SegmentFetcher
	) async throws -> Data {
		try await withThrowingTaskGroup(of: Data.self) { group in
			group.addTask { try await fetch(url) }
			group.addTask {
				try await Task.sleep(until: deadline, clock: .continuous)
				throw DashAudio.fetchFailure(for: url)
			}
			defer { group.cancelAll() }
			guard let data = try await group.next() else { throw DashAudio.fetchFailure(for: url) }
			return data
		}
	}
}

/// A local, assembled DASH stream that plays.
public nonisolated struct DashPlayback: Equatable, Sendable {
	public let url: URL
	public let sampleRate: Int?
}

extension DashAudio {
	/// A playable local file for a High/Low track, or nil when the tier is not a DASH
	/// tier or the assembly fails. Main-actor isolated because it reads the session and
	/// its download status.
	@MainActor
	public static func playbackFile(for track: Track, session: Session, preferredQuality: AudioQuality) async -> DashPlayback? {
		guard preferredQuality == .medium || preferredQuality == .low else { return nil }
		if let cached = HiResStreamCache.cachedDashFile(forTrackId: track.id, quality: preferredQuality) {
			print("[PLAYBACK] dash: reusing cached file for \(track.title)")
			return describe(cached)
		}
		guard let manifest = await session.dashAudioManifest(trackId: track.id, audioQuality: preferredQuality) else {
			return nil
		}
		let status = session.helpers.downloadStatus
		status.startTask()
		defer { status.finishTask() }
		let destination = HiResStreamCache.dashFileURL(forTrackId: track.id, quality: preferredQuality)
		do {
			try await assemble(manifest, to: destination)
			HiResStreamCache.pruneIfNeeded()
			print("[PLAYBACK] dash: assembled \(track.title) to cache")
			return describe(destination)
		} catch {
			print("[PLAYBACK] dash: failed for \(track.title): \(error)")
			return nil
		}
	}

	/// The format of a local stream, read from the file itself.
	static func describe(_ url: URL) -> DashPlayback {
		var sampleRate: Int?
		if let file = try? AVAudioFile(forReading: url) {
			sampleRate = Int(file.fileFormat.sampleRate)
		}
		return DashPlayback(url: url, sampleRate: sampleRate)
	}
}
