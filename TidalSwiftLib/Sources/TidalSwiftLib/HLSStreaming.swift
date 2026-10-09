//
//  HLSStreaming.swift
//  TidalSwiftLib
//

import AVFoundation
import Foundation

/// Why an HLS manifest could not be resolved, read or assembled. Every case is a
/// refusal: an HLS source either yields a complete, playable file or fails loudly.
public nonisolated enum HLSStreamError: Error, Equatable, Sendable {
	/// The manifest request was answered with a non-2xx status, such as 403
	/// `CLIENT_NOT_ENTITLED` for a rendition this client may not have.
	case requestRefused(status: Int)
	/// The manifest request never completed.
	case requestFailed
	/// The response carried no `attributes.uri`.
	case missingPlaylistURL
	case malformedPlaylist
	/// A master playlist carried no variant.
	case noVariants
	/// A media playlist had no `#EXT-X-MAP` initialization segment, so the media
	/// segments alone would not form a playable file.
	case missingInitializationSegment
	/// A playlist carried an `#EXT-X-KEY` or `#EXT-X-SESSION-KEY` line, so its media is
	/// encrypted. No key handling exists, so the rung is refused rather than the segments
	/// concatenated into a file that cannot play. Tidal answers this app's desktop session
	/// a playlist with no key line (measured 2026-10-06); this is the guard for the day
	/// that changes.
	case encryptedPlaylist
	/// Only the host is kept, since a segment URL carries its own token.
	case fetchFailed(host: String)
	/// The concatenated bytes are not an MP4 stream, so they were discarded rather
	/// than cached where a later play would treat them as a finished track.
	case notPlayableFile
	case writeFailed(underlying: Error)

	public static func == (lhs: HLSStreamError, rhs: HLSStreamError) -> Bool {
		switch (lhs, rhs) {
		case (.requestRefused(let l), .requestRefused(let r)):
			return l == r
		case (.requestFailed, .requestFailed),
			(.missingPlaylistURL, .missingPlaylistURL),
			(.malformedPlaylist, .malformedPlaylist),
			(.noVariants, .noVariants),
			(.missingInitializationSegment, .missingInitializationSegment),
			(.encryptedPlaylist, .encryptedPlaylist),
			(.notPlayableFile, .notPlayableFile),
			(.writeFailed, .writeFailed):
			return true
		case (.fetchFailed(let l), .fetchFailed(let r)):
			return l == r
		default:
			return false
		}
	}
}

extension HLSStreamError: LocalizedError {
	/// A URL-free sentence for each case. A failure message must never carry the failing URL: a
	/// segment URL's query holds its token, and `String(describing:)` on a wrapped `URLError`
	/// would print it.
	public var errorDescription: String? {
		switch self {
		case .requestRefused(let status):
			"The server refused the request with HTTP \(status)."
		case .requestFailed:
			"The request did not complete."
		case .missingPlaylistURL:
			"The manifest carried no stream URL."
		case .malformedPlaylist:
			"The playlist could not be read."
		case .noVariants:
			"The manifest carried no playable variant."
		case .missingInitializationSegment:
			"The playlist carried no initialization segment."
		case .encryptedPlaylist:
			"The stream is encrypted, so this client cannot play it."
		case .fetchFailed(let host):
			"Could not fetch the stream from \(host)."
		case .notPlayableFile:
			"The downloaded stream is not a playable MP4 file."
		case .writeFailed(let underlying):
			"Could not write the downloaded file: \(underlying.localizedDescription)"
		}
	}
}

/// One entry of an HLS master playlist: a rendition and its bandwidth.
public nonisolated struct HLSVariant: Equatable, Sendable {
	public let bandwidth: Int
	public let codecs: String?
	public let url: URL
}

/// An HLS media playlist: the initialization segment and the media segments that
/// follow it.
public nonisolated struct HLSMediaPlaylist: Equatable, Sendable {
	/// The `#EXT-X-MAP` initialization segment, fetched before the media segments.
	/// Tidal always serves one; a media playlist without it is refused rather than
	/// concatenated into a file that cannot play.
	public let initializationURL: URL?
	public let segmentURLs: [URL]
}

/// A playlist as it is written on the wire: either a multivariant playlist listing
/// renditions or a media playlist listing segments. The multivariant one is the
/// playlist HLS calls the master playlist.
public nonisolated enum HLSPlaylist: Equatable, Sendable {
	case multivariant(variants: [HLSVariant])
	case media(HLSMediaPlaylist)
}

/// One rung of the HLS quality ladder: a stereo tier, or the Dolby Atmos rendition.
///
/// Atmos is not an `AudioQuality`: Tidal files an Atmos track under LOW while the manifest
/// API serves an `EAC3_JOC` variant for it (measured 2026-10-08), so the rendition gets its
/// own rung rather than a tier that would then lie about the bit depth.
public nonisolated enum HLSRung: Equatable, Sendable, Hashable {
	case stereo(AudioQuality)
	case dolbyAtmos

	/// The one format to request for this rung, so the playlist holds exactly that variant.
	/// Upper case is required; the endpoint rejects lower case.
	public var format: String {
		switch self {
		case .stereo(.max):
			return "FLAC_HIRES"
		case .stereo(.high):
			return "FLAC"
		case .stereo(.medium):
			return "AACLC"
		case .stereo(.low):
			return "HEAACV1"
		case .dolbyAtmos:
			return "EAC3_JOC"
		}
	}

	/// The stereo tier this rung serves, or nil for the Atmos rendition.
	public var quality: AudioQuality? {
		switch self {
		case .stereo(let quality):
			return quality
		case .dolbyAtmos:
			return nil
		}
	}

	/// The name component the playback cache uses for this rung, so a Max file is never
	/// served at Lossless and an Atmos file is never served as a stereo tier.
	var fileMarker: String {
		switch self {
		case .stereo(let quality):
			return quality.rawValue
		case .dolbyAtmos:
			return "DOLBY_ATMOS"
		}
	}

	public var isDolbyAtmos: Bool {
		self == .dolbyAtmos
	}
}

/// A manifest Tidal served and the rung that served it. The rung is the one Tidal answered,
/// so it equals the first requested rung only when that rung was served: a refusal steps the
/// ladder down and the served rung is reported here.
public nonisolated struct HLSManifest: Equatable, Sendable {
	public let playlistURL: URL
	public let rung: HLSRung
}

/// Reads an HLS playlist. Tidal serves a VOD fMP4 playlist: a master naming the
/// renditions, and one media playlist per rendition with an initialization segment
/// and 4-second media segments.
public nonisolated enum HLSPlaylistParser {
	/// Parses `text`, resolving every relative URI against the playlist's own URL.
	///
	/// A playlist that is neither a master nor a media playlist is refused with
	/// `malformedPlaylist` rather than read as an empty one.
	public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
		let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
		guard lines.contains("#EXTM3U") else { throw HLSStreamError.malformedPlaylist }

		var variants: [HLSVariant] = []
		var pendingBandwidth: Int?
		var pendingCodecs: String?
		var initializationURL: URL?
		var segmentURLs: [URL] = []
		var sawMediaTag = false

		for line in lines where !line.isEmpty {
			if line.hasPrefix("#EXT-X-STREAM-INF:") {
				let attributes = attributeList(of: line)
				pendingBandwidth = attributes["BANDWIDTH"].flatMap(Int.init) ?? 0
				pendingCodecs = attributes["CODECS"]
			} else if line.hasPrefix("#EXT-X-MAP:") {
				initializationURL = attributeList(of: line)["URI"].flatMap { resolve($0, against: baseURL) }
				sawMediaTag = true
			} else if line.hasPrefix("#EXTINF") || line.hasPrefix("#EXT-X-TARGETDURATION") || line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
				sawMediaTag = true
			} else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
				// Encrypted media cannot be assembled into a file that plays, and no key
				// handling exists, so the whole playlist is refused instead of its bytes
				// written somewhere they can never play.
				throw HLSStreamError.encryptedPlaylist
			} else if line.hasPrefix("#") {
				continue
			} else if let bandwidth = pendingBandwidth {
				// A URI line under a `#EXT-X-STREAM-INF` is that variant's playlist.
				guard let url = resolve(line, against: baseURL) else { throw HLSStreamError.malformedPlaylist }
				variants.append(HLSVariant(bandwidth: bandwidth, codecs: pendingCodecs, url: url))
				pendingBandwidth = nil
				pendingCodecs = nil
			} else if let url = resolve(line, against: baseURL) {
				segmentURLs.append(url)
				sawMediaTag = true
			}
		}

		if !variants.isEmpty {
			return .multivariant(variants: variants)
		}
		guard sawMediaTag || initializationURL != nil || !segmentURLs.isEmpty else {
			throw HLSStreamError.malformedPlaylist
		}
		return .media(HLSMediaPlaylist(initializationURL: initializationURL, segmentURLs: segmentURLs))
	}

	/// Splits a tag's comma-separated `KEY=VALUE` list; a quoted value may contain a
	/// comma, so the split skips commas inside quotes. Keys are upper-cased so a
	/// lookup does not depend on the tag's own casing.
	static func attributeList(of line: String) -> [String: String] {
		guard let colon = line.firstIndex(of: ":") else { return [:] }
		var attributes: [String: String] = [:]
		var key = ""
		var value = ""
		var inQuotes = false
		var readingValue = false

		func commit() {
			let name = key.trimmingCharacters(in: .whitespaces).uppercased()
			if !name.isEmpty {
				attributes[name] = value
			}
			key = ""
			value = ""
			readingValue = false
		}

		for character in line[line.index(after: colon)...] {
			if character == "\"" {
				inQuotes.toggle()
			} else if character == "," && !inQuotes {
				commit()
			} else if character == "=" && !inQuotes && !readingValue {
				readingValue = true
			} else if readingValue {
				value.append(character)
			} else {
				key.append(character)
			}
		}
		commit()
		return attributes
	}

	/// Resolves a playlist URI, absolute or relative to the playlist's own URL.
	static func resolve(_ uri: String, against baseURL: URL) -> URL? {
		URL(string: uri, relativeTo: baseURL)?.absoluteURL.upgradedToHTTPS
	}
}

/// Resolves Tidal's HLS manifest, downloads the variant it names and concatenates the
/// segments into one cached file.
///
/// The manifest host is `openapi.tidal.com`, and this app's desktop-client session is
/// answered a playlist with no key line at all (measured 2026-10-06), so nothing here
/// is encrypted and no key handling exists.
public nonisolated enum HLSStreaming {
	/// Fetches one resource. The default reads `file://` URLs directly, `URLSession`
	/// otherwise; tests substitute a closure so no network is needed.
	public typealias ResourceFetcher = @Sendable (URL) async throws -> Data

	/// A file shorter than this is a stub left by an interrupted download.
	static let minimumPlayableFileBytes = 512
	/// The MP4 box types a concatenated file may begin with: the `ftyp` box is the
	/// usual head of an fMP4 init segment, with `styp` used by DASH segments.
	static let mp4BoxTypes: Set<String> = ["ftyp", "styp", "moov"]

	/// The tiers a chosen quality walks down, chosen tier first. The quality selector is a
	/// ceiling, not an exact tier: hi-res is rare (measured 2026-10-06, seven of eight tracks
	/// refused `FLAC_HIRES`), so a refusal at the chosen tier is the common path and the next
	/// lower rendition is the answer.
	public static func qualityLadder(for quality: AudioQuality) -> [AudioQuality] {
		let descending = Array(AudioQualityPolicy.ladder.reversed())
		guard let index = descending.firstIndex(of: quality) else { return [] }
		return Array(descending[index...])
	}

	/// The rungs a play asks for, in order.
	///
	/// Stereo is never gated on the advertised modes: the catalogue omits STEREO for tracks
	/// the manifest API still serves FLAC for (measured 2026-10-08), so the manifest decides
	/// what exists. A track that advertises Atmos also gets that rung when the ceiling admits
	/// it; the preference puts it first, and without the preference it is the fallback, so an
	/// Atmos-only track plays either way. The preference chooses, it never removes a rung.
	///
	/// The ceiling also gates the Atmos rung: a Medium or Low ceiling only walks the stereo
	/// ladder, so a 96 kbps setting never plays the ~768 kbps E-AC-3 rendition
	/// (`AudioQuality.admitsDolbyAtmos`).
	public static func rungs(for quality: AudioQuality, preferDolbyAtmos: Bool, trackHasDolbyAtmos: Bool) -> [HLSRung] {
		let stereo = qualityLadder(for: quality).map(HLSRung.stereo)
		guard trackHasDolbyAtmos, quality.admitsDolbyAtmos else { return stereo }
		return preferDolbyAtmos ? [.dolbyAtmos] + stereo : stereo + [.dolbyAtmos]
	}

	/// Resolves the first rung in order that is served, asking no rung after the one that
	/// answered. A refusal at a rung is the next rung, not an error: only when every rung is
	/// refused does this throw, and it throws the last refusal.
	///
	/// Cancellation is not a refusal: a cancelled resolve stops at once instead of asking the
	/// remaining rungs, so a cancelled sync does not keep hitting the network.
	static func resolveManifest(
		trackId: Int,
		rungs: [HLSRung],
		resolve: (Int, HLSRung) async throws -> URL
	) async throws -> HLSManifest {
		var lastError: Error = HLSStreamError.requestFailed
		for rung in rungs {
			if Task.isCancelled { throw CancellationError() }
			do {
				return HLSManifest(playlistURL: try await resolve(trackId, rung), rung: rung)
			} catch {
				if isCancellation(error) { throw error }
				lastError = error
			}
		}
		throw lastError
	}

	/// Whether `error` is a cancellation rather than a refusal, so a ladder stops instead of
	/// walking on to the next rung. `URLSession` reports a cancelled request as
	/// `URLError.cancelled`, and structured concurrency as `CancellationError`.
	static func isCancellation(_ error: Error) -> Bool {
		if error is CancellationError { return true }
		if let urlError = error as? URLError, urlError.code == .cancelled { return true }
		return false
	}

	/// With one format requested the multivariant playlist should hold a single variant;
	/// when Tidal still returns several, the highest `BANDWIDTH` wins, so the choice is
	/// deterministic rather than dependent on playlist order.
	static func highestBandwidthVariant(in variants: [HLSVariant]) throws -> HLSVariant {
		guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
			throw HLSStreamError.noVariants
		}
		return best
	}

	/// The default fetcher: a local read for `file://`, a plain GET presenting
	/// `userAgent` otherwise. Segment and playlist URLs carry their own token and
	/// need no auth header.
	static func defaultFetch(userAgent: String) -> ResourceFetcher {
		{ url in
			if url.isFileURL {
				return try Data(contentsOf: url)
			}
			var request = URLRequest(url: url)
			request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
			let (data, response) = try await URLSession.shared.data(for: request)
			if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
				throw HLSStreamError.fetchFailed(host: url.host ?? "unknown")
			}
			return data
		}
	}

	/// Reads the multivariant playlist, picks its variant, then follows that variant's
	/// media playlist so its initialization segment and media segments can be fetched.
	@concurrent
	static func mediaPlaylist(from multivariantURL: URL, fetch: @escaping ResourceFetcher) async throws -> HLSMediaPlaylist {
		let playlist = try HLSPlaylistParser.parse(try await text(at: multivariantURL, fetch: fetch), baseURL: multivariantURL)
		switch playlist {
		case .media(let media):
			return media
		case .multivariant(let variants):
			let variant = try highestBandwidthVariant(in: variants)
			let parsed = try HLSPlaylistParser.parse(try await text(at: variant.url, fetch: fetch), baseURL: variant.url)
			guard case .media(let media) = parsed else { throw HLSStreamError.malformedPlaylist }
			return media
		}
	}

	/// Fetches the variant's initialization segment and every media segment in order and
	/// writes them to `destination` as one file.
	///
	/// The bytes land in a temporary sibling and are moved onto `destination` only after
	/// they verify, so an interrupted download leaves nothing behind and never looks
	/// cached and complete.
	@concurrent
	static func assemble(_ media: HLSMediaPlaylist, to destination: URL, fetch: @escaping ResourceFetcher) async throws {
		guard let initializationURL = media.initializationURL else {
			throw HLSStreamError.missingInitializationSegment
		}
		guard !media.segmentURLs.isEmpty else { throw HLSStreamError.malformedPlaylist }

		let temporary = destination
			.deletingLastPathComponent()
			.appendingPathComponent(temporarySiblingName(for: destination))
		defer { try? FileManager.default.removeItem(at: temporary) }
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		FileManager.default.createFile(atPath: temporary.path, contents: nil)

		do {
			let output = try FileHandle(forWritingTo: temporary)
			defer { try? output.close() }
			try output.write(contentsOf: try await data(at: initializationURL, fetch: fetch))
			for url in media.segmentURLs {
				try Task.checkCancellation()
				try output.write(contentsOf: try await data(at: url, fetch: fetch))
			}
			try output.close()
		} catch let error as HLSStreamError {
			throw error
		} catch let error as CancellationError {
			throw error
		} catch {
			throw HLSStreamError.writeFailed(underlying: error)
		}

		// A temporary file that is gone after the write loop was removed from under the
		// download, not written with bytes that cannot play. Asking the verifier about a file
		// that was never written would blame the content for a write that never landed, so a
		// missing file is a write failure and the verifier only judges bytes that are there.
		guard FileManager.default.fileExists(atPath: temporary.path) else {
			throw HLSStreamError.writeFailed(underlying: CocoaError(.fileNoSuchFile))
		}
		guard isPlayableMP4File(at: temporary) else { throw HLSStreamError.notPlayableFile }
		do {
			try install(temporary, at: destination)
		} catch {
			throw HLSStreamError.writeFailed(underlying: error)
		}
	}

	/// Downloads the whole variant named by `playlistURL` into `destination` as one file.
	/// The play path's cache write and the offline sync's download are both this.
	static func download(_ playlistURL: URL, to destination: URL, fetch: @escaping ResourceFetcher) async throws {
		let media = try await mediaPlaylist(from: playlistURL, fetch: fetch)
		try await assemble(media, to: destination, fetch: fetch)
	}

	/// Downloads the whole variant named by `playlistURL` into `cacheDirectory` and
	/// returns the file's URL.
	static func downloadToCache(
		_ playlistURL: URL,
		forTrackId trackId: Int,
		rung: HLSRung,
		cacheDirectory: URL,
		fetch: @escaping ResourceFetcher
	) async throws -> URL {
		let destination = PlaybackCache.fileURL(forTrackId: trackId, rung: rung, in: cacheDirectory)
		try await download(playlistURL, to: destination, fetch: fetch)
		return destination
	}

	/// Whether `url` is a non-trivial MP4 stream, checked before a file is installed and
	/// again before a cached one is served, so a stub is a miss rather than a track that
	/// plays a second and stops.
	static func isPlayableMP4File(at url: URL) -> Bool {
		let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
		let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
		guard size >= minimumPlayableFileBytes else { return false }
		guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 8) else {
			return false
		}
		try? handle.close()
		guard header.count == 8 else { return false }
		guard let boxType = String(bytes: header.subdata(in: 4..<8), encoding: .ascii) else { return false }
		return mp4BoxTypes.contains(boxType)
	}

	/// Whether `url` is a temporary sibling `assemble` leaves while it writes its
	/// destination. A hard crash mid-download skips the `defer` that removes it, so the
	/// file can outlive the process; the offline sync clears these.
	static func isTemporarySibling(_ url: URL) -> Bool {
		let name = url.lastPathComponent
		return name.hasPrefix(".") && name.contains(".tmp-")
	}

	/// The hidden sibling `assemble` writes before installing the destination.
	private static func temporarySiblingName(for destination: URL) -> String {
		".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
	}

	/// Moves the verified temporary file onto `destination`, replacing any file there.
	private static func install(_ temporary: URL, at destination: URL) throws {
		if FileManager.default.fileExists(atPath: destination.path) {
			_ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
		} else {
			try FileManager.default.moveItem(at: temporary, to: destination)
		}
	}

	private static func text(at url: URL, fetch: @escaping ResourceFetcher) async throws -> String {
		String(data: try await data(at: url, fetch: fetch), encoding: .utf8) ?? ""
	}

	/// Fetches one resource, keeping cancellation and an already-typed error intact and
	/// naming only the host for anything else.
	private static func data(at url: URL, fetch: @escaping ResourceFetcher) async throws -> Data {
		do {
			return try await fetch(url)
		} catch let error as HLSStreamError {
			throw error
		} catch let error as CancellationError {
			throw error
		} catch let error as URLError where error.code == .cancelled {
			throw error
		} catch {
			throw HLSStreamError.fetchFailed(host: url.host ?? "unknown")
		}
	}
}

/// De-duplicates concurrent cache downloads of one track at one rung, so a play racing a
/// prefetch of the same track fetches the bytes once instead of twice.
///
/// The key carries the cache directory, the track id and the rung: they name different files
/// and must never share one download. A caller that arrives while the download for a key runs
/// awaits that one; the entry is cleared when it finishes, so a later request starts fresh.
actor HLSStreamPreparation {
	static let shared = HLSStreamPreparation()
	private var inFlight: [String: Task<URL?, Never>] = [:]

	/// Runs `operation` once per `key`; a concurrent caller for the same key awaits the
	/// running task's result instead of starting its own.
	func run(key: String, operation: @escaping @Sendable () async -> URL?) async -> URL? {
		if let existing = inFlight[key] {
			return await existing.value
		}
		let task = Task { await operation() }
		inFlight[key] = task
		let result = await task.value
		inFlight[key] = nil
		return result
	}

	/// The key for one track's cache download at one rung.
	static func key(trackId: Int, rung: HLSRung, cacheDirectory: URL) -> String {
		"\(cacheDirectory.path)#\(trackId)#\(rung.fileMarker)"
	}
}

extension Session {
	/// Resolves a track's HLS multivariant (master) playlist through openapi's
	/// `trackManifests`, walking the rung ladder and returning the first rung Tidal
	/// serves.
	///
	/// The quality is a ceiling: a refusal at the chosen tier (hi-res is the common refusal)
	/// steps to the next lower rendition rather than failing, so this returns a URL whenever
	/// any stereo tier is available. A track that advertises Atmos is offered the Atmos rung
	/// too when the ceiling admits it; the preference puts it first. See `HLSStreaming.rungs`.
	public func hlsPlaylistURL(
		trackId: Int,
		audioQuality: AudioQuality,
		preferDolbyAtmos: Bool = false,
		trackHasDolbyAtmos: Bool = false
	) async throws -> URL {
		let rungs = HLSStreaming.rungs(
			for: audioQuality,
			preferDolbyAtmos: preferDolbyAtmos,
			trackHasDolbyAtmos: trackHasDolbyAtmos
		)
		return try await HLSStreaming.resolveManifest(trackId: trackId, rungs: rungs) { trackId, rung in
			try await self.hlsManifestRequest(trackId: trackId, rung: rung)
		}.playlistURL
	}

	/// One rung's HLS multivariant (master) playlist through openapi's `trackManifests`.
	///
	/// The request names one format for `rung`, so the playlist holds exactly that variant,
	/// and carries this session's own token with no `X-Tidal-Token` — the shape the manifest
	/// was measured with (2026-10-06). A desktop-client session is answered a playlist with no
	/// key line, which is why nothing here is decrypted.
	///
	/// `adaptive=true` is required: the endpoint answers 400 without it.
	func hlsManifestRequest(trackId: Int, rung: HLSRung) async throws -> URL {
		let parameters = [
			"manifestType": "HLS",
			"uriScheme": "HTTPS",
			"usage": "PLAYBACK",
			"adaptive": "true",
			"formats": rung.format
		]
		var components = URLComponents(string: "\(AuthInformation.APIV2OpenAPILocation)/trackManifests/\(trackId)")!
		components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
		guard let url = components.url else { throw HLSStreamError.requestFailed }

		try? await refreshAccessTokenIfNeeded()
		var response = try await sendManifestRequest(url)
		if response.statusCode == 401, Self.isAuthenticationFailure(response) {
			try await refreshAccessToken()
			response = try await sendManifestRequest(url)
		}
		guard (200..<300).contains(response.statusCode ?? 0) else {
			throw HLSStreamError.requestRefused(status: response.statusCode ?? 0)
		}
		guard let resource = try? JSONDecoder.custom.decode(TrackManifestResponse.self, from: response.data),
			  let uri = resource.data?.attributes?.uri,
			  let playlistURL = URL(string: uri) else {
			throw HLSStreamError.missingPlaylistURL
		}
		return playlistURL.upgradedToHTTPS
	}

	/// The manifest request carries the session token and the desktop identity, and no
	/// `X-Tidal-Token`: the device client token is what makes Tidal answer a manifest
	/// wrapped in FairPlay.
	private func sendManifestRequest(_ url: URL) async throws -> Response {
		var request = URLRequest(url: url)
		request.setValue(config.accessToken, forHTTPHeaderField: "Authorization")
		request.setValue(AuthInformation.tidalClientUserAgent, forHTTPHeaderField: "User-Agent")
		request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
		do {
			let (data, response) = try await requestSession.data(for: request)
			return Response(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode, etag: nil)
		} catch {
			if HLSStreaming.isCancellation(error) { throw error }
			throw HLSStreamError.requestFailed
		}
	}
}

/// JSON:API envelope of `GET /trackManifests/{id}`.
struct TrackManifestResponse: Decodable {
	let data: TrackManifestResource?
}

struct TrackManifestResource: Decodable {
	let attributes: TrackManifestAttributes?
}

struct TrackManifestAttributes: Decodable {
	let uri: String?
}

/// Where a play starts, and the cache write running behind it.
public struct HLSPlaybackSource {
	/// The cached file when one is present, otherwise the track's HLS playlist.
	public let url: URL
	/// The rung Tidal served, which is the Atmos rendition or a lower stereo tier when the
	/// chosen one was refused; the badge and the cache name read this, not the request.
	public let rung: HLSRung
	/// Read from a cached file; nil while streaming, since a playlist reports no format
	/// synchronously.
	public let sampleRate: Int?
	/// The background cache write, so a caller that needs the file can wait for it.
	/// A play discards it: the point is that nothing waits.
	public let backgroundDownload: Task<URL?, Never>?
}

extension HLSStreaming {
	/// The URL to hand the player for `track`, and the cache write started behind it.
	///
	/// A cached file wins and does nothing else. Otherwise the playlist is resolved and
	/// returned as it stands, so playback starts without waiting, while that same
	/// playlist is downloaded into the cache for a later play. Returns `nil` when the
	/// manifest cannot be resolved, so the caller keeps walking its route ladder.
	@MainActor
	public static func playbackSource(
		for track: Track,
		session: Session,
		quality: AudioQuality,
		preferDolbyAtmos: Bool = false,
		cacheDirectory: URL = PlaybackCache.directory,
		protecting: Set<Int> = [],
		queueTrackIds: Set<Int> = [],
		resolvePlaylist: ((Int, HLSRung) async throws -> URL)? = nil,
		fetch: ResourceFetcher? = nil
	) async -> HLSPlaybackSource? {
		let rungs = rungs(for: quality, preferDolbyAtmos: preferDolbyAtmos, trackHasDolbyAtmos: track.hasDolbyAtmos)
		if let cached = PlaybackCache.cachedFile(forTrackId: track.id, rungs: rungs, in: cacheDirectory) {
			PlaybackCache.touch(cached.url)
			print("[PLAYBACK] hls: reusing cached file for \(track.title)")
			return HLSPlaybackSource(
				url: cached.url,
				rung: cached.rung,
				sampleRate: sampleRate(of: cached.url),
				backgroundDownload: nil
			)
		}

		// The seam is one rung's playlist; the ladder above it is walked here, so a refusal
		// at the chosen rung is the next rung rather than a track that cannot play.
		let resolver = resolvePlaylist ?? { trackId, rung in
			try await session.hlsManifestRequest(trackId: trackId, rung: rung)
		}
		let manifest: HLSManifest
		do {
			manifest = try await resolveManifest(trackId: track.id, rungs: rungs, resolve: resolver)
		} catch let error as HLSStreamError {
			print("[PLAYBACK] hls: no manifest for \(track.title): \(error)")
			return nil
		} catch {
			print("[PLAYBACK] hls: no manifest for \(track.title)")
			return nil
		}
		if manifest.rung != rungs.first {
			print("[PLAYBACK] hls: stepped \(track.title) down to \(manifest.rung.format)")
		}

		// Fire and forget: the playlist plays now, the file lands when it lands.
		let download = cacheInBackground(
			manifest.playlistURL,
			forTrackId: track.id,
			rung: manifest.rung,
			cacheDirectory: cacheDirectory,
			protecting: protecting,
			queueTrackIds: queueTrackIds,
			fetch: fetch ?? defaultFetch(userAgent: AuthInformation.tidalClientUserAgent)
		)
		print("[PLAYBACK] hls: streaming \(track.title) from the playlist at \(manifest.rung.format)")
		return HLSPlaybackSource(
			url: manifest.playlistURL,
			rung: manifest.rung,
			sampleRate: nil,
			backgroundDownload: download
		)
	}

	/// A playable local file for `track` at `quality`, waiting for the cache write when
	/// one is needed. Returns `nil` when the tier cannot be resolved. The player streams
	/// via `playbackSource` instead; this is for a caller that wants the file itself.
	/// `cacheDirectory`, `resolvePlaylist` and `fetch` are seams for a test.
	@MainActor
	public static func playbackFile(
		for track: Track,
		session: Session,
		quality: AudioQuality,
		preferDolbyAtmos: Bool = false,
		cacheDirectory: URL? = nil,
		protecting: Set<Int> = [],
		queueTrackIds: Set<Int> = [],
		resolvePlaylist: ((Int, HLSRung) async throws -> URL)? = nil,
		fetch: ResourceFetcher? = nil
	) async -> URL? {
		guard let source = await playbackSource(
			for: track,
			session: session,
			quality: quality,
			preferDolbyAtmos: preferDolbyAtmos,
			cacheDirectory: cacheDirectory ?? PlaybackCache.directory,
			protecting: protecting,
			queueTrackIds: queueTrackIds,
			resolvePlaylist: resolvePlaylist,
			fetch: fetch
		) else {
			return nil
		}
		guard let download = source.backgroundDownload else { return source.url }
		return await download.value
	}

	/// Downloads `playlistURL` into the cache off the main actor, so a play does not wait
	/// for it. Never throws: a failure is logged and the track still plays from the
	/// playlist.
	///
	/// The prune runs under the caller's protection: the track being cached is always
	/// protected, plus whatever the play or the prefetcher passes (the current track, the
	/// prefetch window and the queue), so a background write never evicts what plays next.
	///
	/// A concurrent request for the same track and rung shares one download through
	/// `HLSStreamPreparation`, so a play racing a prefetch of the same track fetches it once.
	@discardableResult
	static func cacheInBackground(
		_ playlistURL: URL,
		forTrackId trackId: Int,
		rung: HLSRung,
		cacheDirectory: URL,
		protecting: Set<Int> = [],
		queueTrackIds: Set<Int> = [],
		fetch: @escaping ResourceFetcher
	) -> Task<URL?, Never> {
		let key = HLSStreamPreparation.key(trackId: trackId, rung: rung, cacheDirectory: cacheDirectory)
		return Task.detached(priority: .utility) {
			await HLSStreamPreparation.shared.run(key: key) {
				do {
					let destination = try await downloadToCache(
						playlistURL,
						forTrackId: trackId,
						rung: rung,
						cacheDirectory: cacheDirectory,
						fetch: fetch
					)
					var protected = protecting
					protected.insert(trackId)
					PlaybackCache.pruneIfNeeded(in: cacheDirectory, protecting: protected, queueTrackIds: queueTrackIds)
					print("[PLAYBACK] hls: cached track \(trackId) at \(rung.format)")
					return destination
				} catch {
					// `localizedDescription`: the error itself can carry the failing playlist URL (and
					// its token) through `String(describing:)`.
					print("[PLAYBACK] hls: background cache failed for track \(trackId): \(error.localizedDescription)")
					return nil
				}
			}
		}
	}

	/// The sample rate of a local file (a cached one or an offline copy), or nil when the file
	/// does not report one. A FLAC-in-fMP4 file often does not, so this stays optional rather
	/// than guessed.
	public static func sampleRate(of url: URL) -> Int? {
		guard let file = try? AVAudioFile(forReading: url) else { return nil }
		let rate = Int(file.fileFormat.sampleRate)
		return rate > 0 ? rate : nil
	}

	/// The badge for a rung. Tidal's fMP4 FLAC reports `bitsPerChannel` as 0, so the rung
	/// that served the stream is the only honest source of the label; the sample rate is
	/// appended when the stream reported one. Pass the served rung, never the requested one.
	public static func badge(for rung: HLSRung, sampleRate: Int? = nil) -> String {
		switch rung {
		case .stereo(let quality):
			return badge(for: quality, sampleRate: sampleRate)
		case .dolbyAtmos:
			return "Dolby Atmos"
		}
	}

	/// The badge for a stereo tier. Tidal's fMP4 FLAC reports `bitsPerChannel` as 0, so the
	/// tier that served the stream is the only honest source of the bit depth; the sample rate
	/// is appended when the stream reported one. Pass the served tier, never the requested one.
	public static func badge(for quality: AudioQuality, sampleRate: Int? = nil) -> String {
		switch quality {
		case .max:
			return bitDepthBadge(24, sampleRate: sampleRate)
		case .high:
			return bitDepthBadge(16, sampleRate: sampleRate)
		case .medium:
			return "320 kbps"
		case .low:
			return "96 kbps"
		}
	}

	private static func bitDepthBadge(_ bitDepth: Int, sampleRate: Int?) -> String {
		guard let sampleRate, sampleRate > 0 else { return "\(bitDepth)-bit" }
		return "\(bitDepth)-bit \(formattedSampleRate(sampleRate))"
	}

	private static func formattedSampleRate(_ sampleRate: Int) -> String {
		let kilohertz = Double(sampleRate) / 1000
		if kilohertz == kilohertz.rounded() {
			return "\(Int(kilohertz))kHz"
		}
		return String(format: "%.1fkHz", kilohertz)
	}
}
