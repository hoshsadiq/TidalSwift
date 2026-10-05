//
//  HiResStreaming.swift
//  TidalSwiftLib
//

import AVFoundation
import Foundation

/// Which path a track's playback or download takes, in the order to try.
public enum HiResStreamingRoute: Equatable {
	/// Tidal's desktop `playbackinfo` rendition: 24-bit stereo FLAC, decrypted locally.
	case hiResStereo
	/// Today's path: the stereo `streamUrl` ladder, with the Atmos manifest fallback.
	case standard
}

/// Decides the route for a track, with no view, no storage and no session, so the
/// rule can be exercised directly — the same shape as `AudioQualityPolicy`.
///
/// The rule, in order:
/// 1. The Atmos preference wins outright when the track has an Atmos rendition. Atmos
///    is played through the standard route, which asks for it explicitly.
/// 2. Otherwise the best rendition at or below the selected quality is the first
///    route. `Max` takes the desktop rendition first because it is the only way to
///    24-bit. `Lossless` takes the standard route first: it serves the same 16-bit
///    file, unencrypted and without a download, and the desktop route stays behind it
///    as the rescue for tracks the standard route refuses. Below `Lossless` there is
///    no FLAC to fetch, so the standard route is the whole answer and the fallback
///    chain is left to the lane that builds the DASH path.
/// 3. A session without the `cuk` capability, or the preference switched off, keeps
///    today's behaviour exactly.
public enum HiResStreamingPolicy {
	public static func routes(
		sessionHasHiResStereoAccess: Bool,
		enabled: Bool,
		preferDolbyAtmos: Bool,
		trackHasStereo: Bool,
		trackHasDolbyAtmos: Bool,
		quality: AudioQuality
	) -> [HiResStreamingRoute] {
		if preferDolbyAtmos && trackHasDolbyAtmos {
			return [.standard]
		}
		guard sessionHasHiResStereoAccess, enabled, trackHasStereo else {
			return [.standard]
		}
		switch quality {
		case .max:
			return [.hiResStereo, .standard]
		case .high:
			// A track that also has an Atmos rendition gets no stereo from the standard
			// route at this tier: the stereo stream is refused and the manifest answers
			// with the Atmos rendition, so the rescue has to come first for it. Tracks
			// without Atmos stream their stereo file directly, so the instant route stays
			// first and nothing is downloaded.
			return trackHasDolbyAtmos ? [.hiResStereo, .standard] : [.standard, .hiResStereo]
		case .medium, .low:
			return [.standard]
		}
	}

	/// Whether the first route is the hi-res one, for callers that only need that.
	public static func usesHiResStereo(
		sessionHasHiResStereoAccess: Bool,
		enabled: Bool,
		preferDolbyAtmos: Bool,
		trackHasStereo: Bool,
		trackHasDolbyAtmos: Bool,
		quality: AudioQuality
	) -> Bool {
		routes(
			sessionHasHiResStereoAccess: sessionHasHiResStereoAccess,
			enabled: enabled,
			preferDolbyAtmos: preferDolbyAtmos,
			trackHasStereo: trackHasStereo,
			trackHasDolbyAtmos: trackHasDolbyAtmos,
			quality: quality
		).first == .hiResStereo
	}
}

/// The hi-res stereo preference, owned by the library so the app target needs no
/// wiring beyond the controls in `PreferencesView`, and the player can read them
/// without being handed new values.
///
/// Default on: the route is tried first and falls back quietly, so a user who does
/// not want it opts out rather than in.
public enum HiResStreamingPreferences {
	public static let enabledKey = "hiResStereoEnabled"
	public static let prefetchDepthKey = "hiResStreamPrefetchDepth"
	public static let cacheSizeBytesKey = "hiResStreamCacheBytes"

	public static var isEnabled: Bool {
		UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
	}

	/// How many tracks after the current one are prepared in advance. 0 turns
	/// preparing off; the setting is clamped to `prefetchDepthRange`.
	public static let defaultPrefetchDepth = 3
	public static let prefetchDepthRange = 0...15

	public static var prefetchDepth: Int {
		guard UserDefaults.standard.object(forKey: prefetchDepthKey) != nil else {
			return defaultPrefetchDepth
		}
		return min(max(UserDefaults.standard.integer(forKey: prefetchDepthKey), prefetchDepthRange.lowerBound), prefetchDepthRange.upperBound)
	}

	/// How much disk space prepared tracks may use. The prefetch window and the track
	/// currently playing are exempt, so the cache can exceed this by a track or two.
	public static let defaultCacheBytes = 2 * 1024 * 1024 * 1024
	public static let cacheSizeOptions: [Int] = [1, 2, 3, 4, 6, 8].map { $0 * 1024 * 1024 * 1024 }

	public static var cacheSizeBytes: Int {
		guard UserDefaults.standard.object(forKey: cacheSizeBytesKey) != nil else {
			return defaultCacheBytes
		}
		return max(0, UserDefaults.standard.integer(forKey: cacheSizeBytesKey))
	}
}

extension Session {
	/// Whether this session's token can use the hi-res stereo route.
	///
	/// The signal is the `cuk` (client unique key) claim in the access token; Tidal
	/// answers the desktop endpoint with Atmos instead of stereo when it is absent.
	/// The token lands in `Config.accessToken`, which has no "token set" hook outside
	/// the login code, so the claim is read from the token itself. It is a small
	/// base64 payload and this is called once per play and once by the preferences
	/// view, so decoding it on access is cheaper than adding a stored, writable copy.
	public var hasHiResStereoAccess: Bool {
		HiResStreamingSession.hasHiResStereoClaim(in: config.accessToken)
	}
}

enum HiResStreamingSession {
	/// Reads a `cuk` claim out of a JWT access token. The signature is not checked;
	/// this only asks what the session can do.
	static func hasHiResStereoClaim(in accessToken: String) -> Bool {
		guard let token = accessToken.split(separator: " ").last else { return false }
		let parts = token.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 3,
			  let payload = base64URLDecode(String(parts[1])),
			  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
			return false
		}
		return object["cuk"] != nil
	}

	private static func base64URLDecode(_ string: String) -> Data? {
		var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while value.count % 4 != 0 { value += "=" }
		return Data(base64Encoded: value)
	}
}

/// The local hi-res stream that plays, with the format read from the file itself so
/// the badge describes the audio rather than the request.
public struct HiResPlayback {
	public let url: URL
	public let bitDepth: Int?
	public let sampleRate: Int?
}

/// The stream resolved for a track, whichever route produced it. `Player` plays
/// `url` and needs nothing else; the fields only describe what is playing.
public struct PlayableStream {
	public let url: URL
	public let quality: AudioQuality
	public let isDolbyAtmos: Bool
	/// Whether this is the locally decrypted desktop rendition.
	public let isHiResStereo: Bool
	public let hiResBitDepth: Int?
}

extension Session {
	/// Resolves the stream to play by walking the route policy in order: the first
	/// route that produces a stream wins.
	///
	/// `hiResStereo` yields a local, already-decrypted file, so a prepared track
	/// starts instantly. `standard` yields today's ladder result — a remote URL now,
	/// a local file once the DASH lane lands, with no change here. The Atmos path is
	/// unchanged: it is the `standard` route asked with the Atmos preference.
	public func playableStream(
		for track: Track,
		quality: AudioQuality,
		preferDolbyAtmos: Bool
	) async -> PlayableStream? {
		let preferAtmosForTrack = track.hasDolbyAtmos && preferDolbyAtmos
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: hasHiResStereoAccess,
			enabled: HiResStreamingPreferences.isEnabled,
			preferDolbyAtmos: preferAtmosForTrack,
			trackHasStereo: track.hasStereo,
			trackHasDolbyAtmos: track.hasDolbyAtmos,
			quality: quality
		)
		for route in routes {
			switch route {
			case .hiResStereo:
				if let hiRes = await HiResStreaming.playbackFile(for: track, session: self) {
					print("[PLAYBACK] resolved \(track.title): hi-res stereo")
					return PlayableStream(
						url: hiRes.url,
						quality: .max,
						isDolbyAtmos: false,
						isHiResStereo: true,
						hiResBitDepth: hiRes.bitDepth
					)
				}
			case .standard:
				if let resolved = await bestAudioUrl(
					trackId: track.id,
					preferredQuality: quality,
					preferDolbyAtmos: preferAtmosForTrack
				) {
					print("[PLAYBACK] resolved \(track.title): standard, \(resolved.isDolbyAtmos ? "Dolby Atmos" : resolved.quality.rawValue)")
					return PlayableStream(
						url: resolved.url,
						quality: resolved.quality,
						isDolbyAtmos: resolved.isDolbyAtmos,
						isHiResStereo: false,
						hiResBitDepth: nil
					)
				}
			}
		}
		return nil
	}
}

/// Routes a track through the hi-res stereo path: resolve the encrypted rendition,
/// download it, decrypt it into a local cache, and hand that file to AVPlayer.
/// AVPlayer cannot read the encrypted stream, so the local file is the whole point.
public enum HiResStreaming {
	/// The desktop host the hi-res route lives on. Not `api.tidal.com`: the v1 host
	/// answers Atmos for these tracks and refuses the stereo `streamUrl` entirely.
	static let desktopAPILocation = "https://desktop.tidal.com/v1"

	/// Prunes the playback cache. Called on launch, so a cache that grew while the
	/// app was closed is bounded before it is read.
	public static func pruneCache() {
		HiResStreamCache.pruneIfNeeded()
	}

	/// Prunes the playback cache, exempting the tracks that must not disappear: the
	/// prefetch window and the track currently playing.
	public static func pruneCache(protecting trackIds: Set<Int>) {
		HiResStreamCache.pruneIfNeeded(protecting: trackIds)
	}

	/// Whether a track already has a prepared file in the cache.
	public static func isTrackCached(_ trackId: Int) -> Bool {
		HiResStreamCache.cachedFile(forTrackId: trackId) != nil
	}

	/// How much disk space the prepared-track cache currently uses.
	public static func cacheUsageBytes() -> Int {
		HiResStreamCache.usageBytes()
	}

	/// Whether `track`'s playback or download should take the hi-res stereo route for
	/// this session, when the quality does not enter into it (the download paths ask
	/// only whether the session can use the route at all).
	public static func usesHiResStereo(for track: Track, session: Session) -> Bool {
		HiResStreamingPolicy.usesHiResStereo(
			sessionHasHiResStereoAccess: session.hasHiResStereoAccess,
			enabled: HiResStreamingPreferences.isEnabled,
			preferDolbyAtmos: false,
			trackHasStereo: track.hasStereo,
			trackHasDolbyAtmos: track.hasDolbyAtmos,
			quality: .max
		)
	}

	/// A playable, decrypted local file for `track`, or nil when the route does not
	/// apply or fails — in which case the caller uses today's path.
	public static func playbackFile(for track: Track, session: Session) async -> HiResPlayback? {
		await playbackFile(for: track, session: session, cacheDirectory: HiResStreamCache.directory)
	}

	static func playbackFile(for track: Track, session: Session, cacheDirectory: URL) async -> HiResPlayback? {
		guard let url = await prepareFile(for: track, session: session, cacheDirectory: cacheDirectory) else {
			return nil
		}
		return describe(url)
	}

	/// Makes sure a decrypted local file for `track` exists in the cache and returns
	/// it, or nil when the route does not apply or fails. Shared by playback and the
	/// prefetcher, and de-duplicated per track so a play that arrives while the same
	/// track is being prepared waits for that work rather than downloading twice.
	public static func prepareFile(for track: Track, session: Session) async -> URL? {
		await prepareFile(for: track, session: session, cacheDirectory: HiResStreamCache.directory)
	}

	static func prepareFile(
		for track: Track,
		session: Session,
		cacheDirectory: URL
	) async -> URL? {
		guard usesHiResStereo(for: track, session: session) else {
			return nil
		}
		if let cached = HiResStreamCache.cachedFile(forTrackId: track.id, in: cacheDirectory) {
			HiResStreamCache.touch(cached)
			print("[PLAYBACK] hi-res stereo: reusing cached file for \(track.title)")
			return cached
		}
		return await HiResStreamPreparation.preparedFile(for: track.id, in: cacheDirectory) {
			await downloadFile(for: track, session: session, cacheDirectory: cacheDirectory)
		}
	}

	private static func downloadFile(for track: Track, session: Session, cacheDirectory: URL) async -> URL? {
		guard case .resolved(let manifest) = await session.hiResStereoStream(trackId: track.id) else {
			print("[PLAYBACK] hi-res stereo: no stereo rendition for \(track.title), falling back")
			return nil
		}
		// The download indicator already exists; reusing it keeps the play button
		// from looking stalled while a 30 MB rendition downloads and decrypts.
		let status = session.helpers.downloadStatus
		status.startTask()
		defer { status.finishTask() }
		do {
			let destination = HiResStreamCache.fileURL(forTrackId: track.id, in: cacheDirectory)
			try await downloadAndDecrypt(manifest, to: destination)
			print("[PLAYBACK] hi-res stereo: decrypted \(track.title) to cache")
			return destination
		} catch {
			print("[PLAYBACK] hi-res stereo: failed for \(track.title): \(error), falling back")
			return nil
		}
	}

	/// Builds the prefetcher that prepares upcoming tracks for this session.
	public static func makePrefetcher(
		for session: Session,
		shouldPrepare: @escaping (Track) -> Bool
	) -> HiResStreamPrefetcher {
		HiResStreamPrefetcher(
			depthProvider: { HiResStreamingPreferences.prefetchDepth },
			shouldPrepare: shouldPrepare,
			isCached: { isTrackCached($0.id) },
			prepare: { track in _ = await prepareFile(for: track, session: session) },
			prune: { protected in pruneCache(protecting: protected) }
		)
	}

	/// The format of a local stream, read from the file itself. A file that does not
	/// open still plays but is described without a bit depth rather than guessed at.
	static func describe(_ url: URL) -> HiResPlayback {
		var bitDepth: Int?
		var sampleRate: Int?
		if let file = try? AVAudioFile(forReading: url) {
			sampleRate = Int(file.fileFormat.sampleRate)
			bitDepth = Int(file.fileFormat.streamDescription.pointee.mBitsPerChannel)
		}
		return HiResPlayback(url: url, bitDepth: bitDepth, sampleRate: sampleRate)
	}

	/// Downloads the encrypted rendition and decrypts it into `destination`, so the
	/// bytes on disk are a playable FLAC and never the encrypted stream.
	static func downloadAndDecrypt(_ manifest: AcceptedHiResManifest, to destination: URL) async throws {
		let encrypted = FileManager.default.temporaryDirectory
			.appendingPathComponent("tidal-hires-\(UUID().uuidString).enc")
		defer { try? FileManager.default.removeItem(at: encrypted) }
		try await Network.download(manifest.url, path: encrypted, overwrite: true)
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		// A leftover cache file would otherwise keep its tail under the shorter new one.
		try? FileManager.default.removeItem(at: destination)
		try AudioDecryption.decrypt(fileAt: encrypted, to: destination, keyId: manifest.keyId)
	}
}

/// De-duplicates concurrent preparation of the same track. A play that arrives while
/// the prefetcher is already fetching that track awaits the same work instead of
/// starting a second download.
enum HiResStreamPreparation {
	private static var inFlight: [String: Task<URL?, Never>] = [:]

	static func preparedFile(
		for trackId: Int,
		in directory: URL,
		operation: @escaping () async -> URL?
	) async -> URL? {
		let key = "\(directory.path)#\(trackId)"
		if let existing = inFlight[key] {
			return await existing.value
		}
		let task = Task { await operation() }
		inFlight[key] = task
		let result = await task.value
		inFlight[key] = nil
		return result
	}
}

/// Which upcoming tracks to prepare. Pure, so the window can be tested directly.
public enum HiResPrefetchPolicy {
	/// The tracks after `currentIndex`, in queue order, never wrapping, up to `depth`,
	/// skipping tracks the current settings would not play through the hi-res route and
	/// tracks that are already cached.
	public static func upcomingTracks(
		queue: [Track],
		currentIndex: Int,
		depth: Int,
		shouldPrepare: (Track) -> Bool = { _ in true },
		isCached: (Track) -> Bool = { _ in false }
	) -> [Track] {
		guard depth > 0, queue.indices.contains(currentIndex) else { return [] }
		let end = min(queue.count, currentIndex + 1 + depth)
		guard currentIndex + 1 < end else { return [] }
		return queue[(currentIndex + 1)..<end].filter { shouldPrepare($0) && !isCached($0) }
	}
}

/// Prepares the tracks after the current one in the queue, one at a time, so a track
/// that has already been prepared starts instantly instead of waiting for its
/// download and decrypt.
///
/// It stops after three skips in a row — that is browsing, not listening, and those
/// downloads are wasted — and resumes once a track has played for `settleInterval`
/// without a skip.
public final class HiResStreamPrefetcher {
	public static let browseSkipThreshold = 3

	private let settleInterval: TimeInterval
	private let depthProvider: () -> Int
	private let shouldPrepare: (Track) -> Bool
	private let isCached: (Track) -> Bool
	private let prepare: (Track) async -> Void
	private let prune: (Set<Int>) -> Void

	private var queue: [Track] = []
	private var currentIndex = 0
	private var runTask: Task<Void, Never>?
	private var resumeTask: Task<Void, Never>?
	private var consecutiveSkips = 0
	public private(set) var isPausedForBrowsing = false

	init(
		settleInterval: TimeInterval = 30,
		depthProvider: @escaping () -> Int,
		shouldPrepare: @escaping (Track) -> Bool = { _ in true },
		isCached: @escaping (Track) -> Bool = { _ in false },
		prepare: @escaping (Track) async -> Void,
		prune: @escaping (Set<Int>) -> Void = { _ in }
	) {
		self.settleInterval = settleInterval
		self.depthProvider = depthProvider
		self.shouldPrepare = shouldPrepare
		self.isCached = isCached
		self.prepare = prepare
		self.prune = prune
	}

	/// Called on every track change and every queue change.
	public func queueChanged(queue: [Track], currentIndex: Int) {
		self.queue = queue
		self.currentIndex = currentIndex
		pruneWindow()
		guard !isPausedForBrowsing else { return }
		startPreparing()
	}

	/// Called when the user skips a track.
	public func trackSkipped() {
		consecutiveSkips += 1
		guard consecutiveSkips >= Self.browseSkipThreshold else { return }
		isPausedForBrowsing = true
		runTask?.cancel()
		resumeTask?.cancel()
		let interval = settleInterval
		resumeTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(interval))
			guard !Task.isCancelled, let self else { return }
			self.consecutiveSkips = 0
			self.isPausedForBrowsing = false
			self.startPreparing()
		}
	}

	public func stop() {
		runTask?.cancel()
		resumeTask?.cancel()
		resumeTask = nil
		consecutiveSkips = 0
		isPausedForBrowsing = false
	}

	private func startPreparing() {
		runTask?.cancel()
		let window = HiResPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: currentIndex,
			depth: depthProvider(),
			shouldPrepare: shouldPrepare,
			isCached: isCached
		)
		guard !window.isEmpty else { return }
		// One at a time: firing every track at once would saturate the connection and
		// make the track that is actually playing stutter.
		runTask = Task { [weak self] in
			for track in window {
				guard let self, !Task.isCancelled, !self.isPausedForBrowsing else { return }
				await self.prepare(track)
				self.pruneWindow()
			}
		}
	}

	/// The window and the current track are exempt from eviction: removing a file
	/// prepared for playback would make the whole exercise pointless.
	private func pruneWindow() {
		var protected = Set(HiResPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: currentIndex,
			depth: depthProvider(),
			shouldPrepare: shouldPrepare,
			isCached: { _ in false }
		).map(\.id))
		if queue.indices.contains(currentIndex) {
			protected.insert(queue[currentIndex].id)
		}
		prune(protected)
	}
}

/// The local cache for decrypted hi-res streams, at
/// `~/Library/Caches/TidalSwift/stream/`. Never the offline library: these files are
/// a playback cache, not the user's music. One file per track (`<id>.flac`), reused
/// on replay.
///
/// Bounded in two ways, applied on launch and after every write: files not touched
/// in a week are dropped, then the least recently used are removed until the
/// directory is under the configured size. A file is touched when it is played, so
/// eviction keeps the tracks that actually get listened to.
enum HiResStreamCache {
	static let maxAge: TimeInterval = 7 * 24 * 60 * 60

	static var directory: URL {
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("TidalSwift/stream", isDirectory: true)
	}

	static func fileURL(forTrackId trackId: Int, in directory: URL = HiResStreamCache.directory) -> URL {
		directory.appendingPathComponent("\(trackId).flac")
	}

	static func cachedFile(forTrackId trackId: Int, in directory: URL = HiResStreamCache.directory) -> URL? {
		let url = fileURL(forTrackId: trackId, in: directory)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	static func usageBytes(in directory: URL = HiResStreamCache.directory) -> Int {
		let keys: Set<URLResourceKey> = [.fileSizeKey]
		guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
			return 0
		}
		return contents.reduce(0) { total, url in
			total + ((try? url.resourceValues(forKeys: keys).fileSize) ?? 0)
		}
	}

	/// Marks a cache file as recently used, so LRU eviction keeps the files that
	/// actually play.
	static func touch(_ url: URL, now: Date = Date()) {
		try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
	}

	static func pruneIfNeeded(protecting trackIds: Set<Int> = [], now: Date = Date()) {
		pruneIfNeeded(in: directory, protecting: trackIds, now: now)
	}

	static func pruneIfNeeded(in directory: URL, protecting trackIds: Set<Int> = [], now: Date = Date()) {
		prune(in: directory, maxBytes: HiResStreamingPreferences.cacheSizeBytes, maxAge: maxAge, protecting: trackIds, now: now)
	}

	/// Removes stale files first, then the least recently used until the directory is
	/// under the size cap. A file whose dates cannot be read is treated as old.
	/// Protected tracks are skipped entirely, so the prefetch window and the current
	/// track survive even when that leaves the directory over budget. Returns the
	/// removed URLs so a test can pin what went.
	@discardableResult
	static func prune(in directory: URL, maxBytes: Int, maxAge: TimeInterval, protecting trackIds: Set<Int> = [], now: Date = Date()) -> [URL] {
		let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
		guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
			return []
		}
		let protectedNames = Set(trackIds.map { "\($0).flac" })
		let candidates: [(url: URL, date: Date, size: Int)] = contents.compactMap { url in
			guard !protectedNames.contains(url.lastPathComponent),
				  let values = try? url.resourceValues(forKeys: keys) else { return nil }
			return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
		}
		var remaining = candidates
		var removed: [URL] = []
		for entry in candidates.sorted(by: { $0.date < $1.date }) where now.timeIntervalSince(entry.date) > maxAge {
			try? FileManager.default.removeItem(at: entry.url)
			removed.append(entry.url)
			remaining.removeAll { $0.url == entry.url }
		}
		var total = remaining.reduce(0) { $0 + $1.size }
		for entry in remaining.sorted(by: { $0.date < $1.date }) where total > maxBytes {
			try? FileManager.default.removeItem(at: entry.url)
			removed.append(entry.url)
			total -= entry.size
		}
		return removed
	}
}
