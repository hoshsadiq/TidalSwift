//
//  DashAudio.swift
//  TidalSwiftLib
//

import AVFoundation
import Foundation

/// Why a DASH audio manifest could not be read or assembled. Every case is a
/// refusal: a DASH source either produces a complete, playable file or fails
/// loudly, never a truncated one that plays a few seconds and stops.
public nonisolated enum DashAudioError: Error, Equatable, Sendable {
	/// The MPD is not well-formed XML.
	case malformedManifest
	/// No `<SegmentTemplate>` was found in the document.
	case missingSegmentTemplate
	/// A `<SegmentTemplate>` has no usable `initialization` URL.
	case missingInitializationURL
	/// A `<SegmentTemplate>` has no `media` template.
	case missingMediaTemplate
	/// The `media` template is not a `$Number$` form this app can expand.
	case unsupportedSegmentTemplate
	/// The manifest has no `<SegmentTimeline>` to count segments from.
	case missingSegmentTimeline
	/// A segment or the initialization could not be fetched after retrying.
	case fetchFailed(url: URL)
	/// The destination could not be written.
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

/// A parsed `SegmentTemplate`-based DASH audio manifest: where the initialization
/// and media segments live and how many there are.
///
/// Tidal's High/Low `playbackinfo` answers with one of these (measured 2026-10-05):
/// an `audio/mp4` AAC representation whose segments are plain, unencrypted fMP4.
/// Only the attribute form Tidal ships is understood; anything else is refused
/// rather than guessed at.
public nonisolated struct DashAudioManifest: Equatable, Sendable {
	/// The fixed URL of the initialization segment.
	public let initializationURL: URL
	/// The media template, holding a `$Number$` placeholder.
	public let mediaTemplate: String
	/// The number of the first media segment.
	public let startNumber: Int
	/// The number of media segments, from the `<SegmentTimeline>`.
	public let segmentCount: Int
	/// The timeline timescale, when the manifest reports one.
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

	/// Parses an MPD document into the one representation this app can assemble.
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
		self.initializationURL = initializationURL
		self.mediaTemplate = media
		self.startNumber = Int(template.attributes["startNumber"] ?? "1") ?? 1
		self.segmentCount = template.repeats.reduce(0) { $0 + 1 + $1 }
		self.timescale = template.attributes["timescale"].flatMap(Int.init)
	}

	/// The URL of media segment `number` (starting at `startNumber`).
	public func mediaURL(forNumber number: Int) -> URL? {
		URL(string: mediaTemplate.replacingOccurrences(of: "$Number$", with: String(number)))
	}
}

/// Reads an `<SegmentTemplate>` element out of an MPD. Kept separate from the
/// value type so the parse can be exercised with the raw XML alone.
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

/// Fetches and assembles the media segments of a DASH audio manifest into one
/// file the player can read.
public nonisolated enum DashAudio {
	/// Fetches one resource. The default reads `file://` URLs directly and uses
	/// `URLSession` otherwise; tests substitute a closure so no network is needed
	/// and the order of the assembled segments can be pinned.
	public typealias SegmentFetcher = @Sendable (URL) async throws -> Data

	/// Segments fetched at once. The CDN is cheap to hit but not free, and four
	/// keeps the many small requests from stalling behind each other.
	static let maxConcurrentFetches = 4
	/// A transient CDN failure is retried, but a persistent one is reported rather
	/// than consumed as a shorter file.
	static let maxFetchAttempts = 3
	static let retryBackoff: [Duration] = [.milliseconds(200), .milliseconds(400)]

	/// Downloads the initialization segment plus every media segment and writes
	/// them to `destination` in order, using the default fetcher.
	public static func assemble(_ manifest: DashAudioManifest, to destination: URL) async throws {
		try await assemble(manifest, to: destination, fetch: defaultFetch)
	}

	/// Downloads the initialization segment plus every media segment and writes
	/// them to `destination` in order.
	///
	/// Nothing is written until every segment has been fetched, so a failure
	/// leaves no output file at all: a partial AAC file is worse than an error.
	/// `fetch` is injectable so a test can stand a local directory in for the CDN.
	public static func assemble(
		_ manifest: DashAudioManifest,
		to destination: URL,
		fetch: @escaping SegmentFetcher
	) async throws {
		let initialization = try await fetchWithRetry(manifest.initializationURL, fetch: fetch)
		let numbers = (manifest.startNumber ..< manifest.startNumber + manifest.segmentCount).map { $0 }
		let segments = try await fetchSegments(numbers: numbers, manifest: manifest, fetch: fetch)

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

	/// The default fetcher: a local read for `file://`, a plain GET otherwise.
	/// The CDN segment URLs carry their own token and need no auth header.
	public static func defaultFetch(_ url: URL) async throws -> Data {
		if url.isFileURL {
			return try Data(contentsOf: url)
		}
		// `AuthInformation` is actor-isolated; the desktop UA keeps the request from
		// presenting as this app, the same identity rule the rest of the client follows.
		let userAgent = await MainActor.run { AuthInformation.tidalClientUserAgent }
		var request = URLRequest(url: url)
		request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		let (data, response) = try await URLSession.shared.data(for: request)
		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			throw DashAudioError.fetchFailed(url: url)
		}
		return data
	}

	/// Fetches the segments in bounded batches, preserving order. A single failed
	/// segment aborts the whole group before anything is written.
	private static func fetchSegments(
		numbers: [Int],
		manifest: DashAudioManifest,
		fetch: @escaping SegmentFetcher
	) async throws -> [Data] {
		guard let first = numbers.first, let last = numbers.last,
			  (manifest.startNumber ... manifest.startNumber + manifest.segmentCount).contains(first),
			  (manifest.startNumber ... manifest.startNumber + manifest.segmentCount).contains(last) else {
			throw DashAudioError.unsupportedSegmentTemplate
		}
		var results = [Data?](repeating: nil, count: numbers.count)
		var batchStart = 0
		while batchStart < numbers.count {
			let batchEnd = min(batchStart + maxConcurrentFetches, numbers.count)
			let batch = batchStart ..< batchEnd
			try await withThrowingTaskGroup(of: (Int, Data).self) { group in
				for index in batch {
					guard let url = manifest.mediaURL(forNumber: numbers[index]) else {
						throw DashAudioError.unsupportedSegmentTemplate
					}
					group.addTask { (index, try await fetchWithRetry(url, fetch: fetch)) }
				}
				// Collected by index, so the group's completion order never reorders
				// the segments.
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

	private static func fetchWithRetry(_ url: URL, fetch: SegmentFetcher) async throws -> Data {
		var lastError: Error = DashAudioError.fetchFailed(url: url)
		for attempt in 0 ..< maxFetchAttempts {
			do {
				return try await fetch(url)
			} catch {
				lastError = error
				if attempt < retryBackoff.count {
					try? await Task.sleep(for: retryBackoff[attempt])
				}
			}
		}
		throw lastError
	}
}

/// A local, assembled DASH stream that plays.
public nonisolated struct DashPlayback: Equatable, Sendable {
	public let url: URL
	public let sampleRate: Int?
}

extension DashAudio {
	/// A playable local file for a High/Low track, or nil when the tier is not a
	/// DASH tier or the assembly fails — in which case the caller keeps today's
	/// path.
	///
	/// Mirrors `HiResStreaming.playbackFile`: the assembled file is cached, so a
	/// replay does not re-fetch every segment, and the download indicator is reused
	/// while the segments download. The file lives in the same cache directory as the
	/// decrypted hi-res files and is bounded by the same budget, so the settings
	/// screen's one number is the truth. Main-actor isolated because it reads the
	/// session and its download status.
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

	/// The format of a local stream, read from the file itself so the badge
	/// describes the audio rather than the request.
	static func describe(_ url: URL) -> DashPlayback {
		var sampleRate: Int?
		if let file = try? AVAudioFile(forReading: url) {
			sampleRate = Int(file.fileFormat.sampleRate)
		}
		return DashPlayback(url: url, sampleRate: sampleRate)
	}
}
