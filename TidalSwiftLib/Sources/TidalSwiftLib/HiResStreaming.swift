//
//  HiResStreaming.swift
//  TidalSwiftLib
//

import AVFoundation
import Foundation

/// Which path a track's playback or download takes, in the order to try.
enum HiResStreamingRoute: Equatable {
	/// Tidal's desktop `playbackinfo` rendition: 24-bit stereo FLAC, decrypted locally.
	case hiResStereo
	/// Tidal's High/Low `playbackinfo` rendition: an unencrypted AAC MPD assembled
	/// into a local file, because the direct-stream route cannot play these tiers.
	case dash
	/// The stereo `streamUrl` ladder with the Atmos fallback, and the fall-through route.
	case directStream

	var key: String {
		switch self {
		case .hiResStereo:
			return "hiResStereo"
		case .dash:
			return "dash"
		case .directStream:
			return "directStream"
		}
	}
}

/// Decides the route for a track, with no view, no storage and no session, so the
/// rule can be exercised directly.
///
/// Tidal's desktop `playbackinfo` route leads at every tier and the direct-stream path
/// is the fallback; the Atmos preference wins outright for a track with an Atmos
/// rendition, since only the direct-stream path serves Atmos.
public enum HiResStreamingPolicy {
	static func routes(
		sessionHasHiResStereoAccess: Bool,
		preferDolbyAtmos: Bool,
		trackHasStereo: Bool,
		trackHasDolbyAtmos: Bool,
		quality: AudioQuality
	) -> [HiResStreamingRoute] {
		if preferDolbyAtmos && trackHasDolbyAtmos {
			return [.directStream]
		}
		guard sessionHasHiResStereoAccess, trackHasStereo else {
			return [.directStream]
		}
		switch quality {
		case .max, .high:
			return [.hiResStereo, .directStream]
		case .medium, .low:
			return [.dash, .directStream]
		}
	}

	/// Whether the first route is a local-file route, when preparing a track in advance
	/// is worth the bandwidth.
	public static func usesLocalFile(
		sessionHasHiResStereoAccess: Bool,
		preferDolbyAtmos: Bool,
		trackHasStereo: Bool,
		trackHasDolbyAtmos: Bool,
		quality: AudioQuality
	) -> Bool {
		switch routes(
			sessionHasHiResStereoAccess: sessionHasHiResStereoAccess,
			preferDolbyAtmos: preferDolbyAtmos,
			trackHasStereo: trackHasStereo,
			trackHasDolbyAtmos: trackHasDolbyAtmos,
			quality: quality
		).first {
		case .hiResStereo, .dash:
			return true
		default:
			return false
		}
	}

	static func usesHiResStereo(
		sessionHasHiResStereoAccess: Bool,
		preferDolbyAtmos: Bool,
		trackHasStereo: Bool,
		trackHasDolbyAtmos: Bool,
		quality: AudioQuality
	) -> Bool {
		routes(
			sessionHasHiResStereoAccess: sessionHasHiResStereoAccess,
			preferDolbyAtmos: preferDolbyAtmos,
			trackHasStereo: trackHasStereo,
			trackHasDolbyAtmos: trackHasDolbyAtmos,
			quality: quality
		).first == .hiResStereo
	}
}

/// The hi-res stereo preference, owned by the library so the player can read it.
/// Default on: the route is tried first and falls back quietly, so a user who does
/// not want it opts out rather than in.
public nonisolated enum HiResStreamingPreferences {
	public static let prefetchDepthKey = "hiResStreamPrefetchDepth"
	public static let cacheSizeBytesKey = "hiResStreamCacheBytes"

	/// How many tracks after the current one are prepared in advance; 0 turns it off.
	public static let defaultPrefetchDepth = 3
	public static let prefetchDepthRange = 0...15
	public static let prefetchDepthOptions: [Int] = [0, 1, 2, 3, 5, 8, 10, 15]

	public static var prefetchDepth: Int {
		guard UserDefaults.standard.object(forKey: prefetchDepthKey) != nil else {
			return defaultPrefetchDepth
		}
		return min(max(UserDefaults.standard.integer(forKey: prefetchDepthKey), prefetchDepthRange.lowerBound), prefetchDepthRange.upperBound)
	}

	/// How much disk space prepared tracks may use; the prefetch window and current track are exempt.
	public static let defaultCacheBytes = 2 * 1024 * 1024 * 1024
	/// The budget in gigabytes, bounded so a typo cannot zero it or claim the whole
	/// disk. The stored value is in bytes.
	public static let cacheSizeRange = 1...64

	static let bytesPerGigabyte = 1024 * 1024 * 1024

	public static var cacheSizeBytes: Int {
		cacheSizeBytes(in: .standard)
	}

	/// The stored budget in bytes, clamped to `cacheSizeRange` on read.
	static func cacheSizeBytes(in defaults: UserDefaults) -> Int {
		guard defaults.object(forKey: cacheSizeBytesKey) != nil else {
			return defaultCacheBytes
		}
		let lower = cacheSizeRange.lowerBound * bytesPerGigabyte
		let upper = cacheSizeRange.upperBound * bytesPerGigabyte
		return min(max(defaults.integer(forKey: cacheSizeBytesKey), lower), upper)
	}
}

extension Session {
	/// Whether this session's token can use the hi-res stereo route.
	///
	/// The signal is the `cuk` (client unique key) claim in the access token; Tidal
	/// answers the desktop endpoint with Atmos instead of stereo when it is absent.
	/// The claim is read from the token itself rather than stored, since it is a small
	/// payload read once per play.
	///
	/// - Complexity: O(*n*) in the length of the access token.
	public var hasHiResStereoAccess: Bool {
		HiResStreamingSession.hasHiResStereoClaim(in: config.accessToken)
	}
}

enum HiResStreamingSession {
	/// Reads a `cuk` claim out of a JWT access token; the signature is not checked.
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

/// The local hi-res stream that plays, with the format read from the file itself.
nonisolated struct HiResPlayback {
	let url: URL
	let bitDepth: Int?
	let sampleRate: Int?
}

/// The stream resolved for a track, whichever route produced it. `Player` plays `url`.
public struct PlayableStream {
	public let url: URL
	public let quality: AudioQuality
	public let isDolbyAtmos: Bool
	public let isHiResStereo: Bool
	public let hiResBitDepth: Int?
	public let hiResSampleRate: Int?
}

extension Session {
	/// Resolves the stream to play by walking the route policy in order: the first
	/// route that produces a stream wins.
	public func playableStream(
		for track: Track,
		quality: AudioQuality,
		preferDolbyAtmos: Bool
	) async -> PlayableStream? {
		let preferAtmosForTrack = track.hasDolbyAtmos && preferDolbyAtmos
		let routes = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: hasHiResStereoAccess,
			preferDolbyAtmos: preferAtmosForTrack,
			trackHasStereo: track.hasStereo,
			trackHasDolbyAtmos: track.hasDolbyAtmos,
			quality: quality
		)
		let resolver = PlaybackRouteResolver(
			hiResStereo: { await self.hiResStereoPlayableStream(for: track, quality: quality) },
			dash: { await self.dashPlayableStream(for: track, quality: quality) },
			directStream: { await self.directPlayableStream(for: track, quality: quality, preferAtmos: preferAtmosForTrack) }
		)
		return await resolver.resolve(routes: routes)
	}

	private func hiResStereoPlayableStream(for track: Track, quality: AudioQuality) async -> PlayableStream? {
		guard let hiRes = await HiResStreaming.playbackFile(for: track, session: self, quality: quality) else { return nil }
		print("[PLAYBACK] resolved \(track.title): hi-res stereo, \(quality.rawValue)")
		return PlayableStream(
			url: hiRes.url,
			quality: quality,
			isDolbyAtmos: false,
			isHiResStereo: true,
			hiResBitDepth: hiRes.bitDepth,
			hiResSampleRate: hiRes.sampleRate
		)
	}

	private func dashPlayableStream(for track: Track, quality: AudioQuality) async -> PlayableStream? {
		guard let dash = await HiResStreaming.dashPlaybackFile(for: track, session: self, quality: quality) else { return nil }
		print("[PLAYBACK] resolved \(track.title): dash, \(quality.rawValue)")
		return PlayableStream(
			url: dash.url,
			quality: quality,
			isDolbyAtmos: false,
			isHiResStereo: false,
			hiResBitDepth: nil,
			hiResSampleRate: nil
		)
	}

	private func directPlayableStream(for track: Track, quality: AudioQuality, preferAtmos: Bool) async -> PlayableStream? {
		guard let resolved = await bestAudioUrl(
			trackId: track.id,
			preferredQuality: quality,
			preferDolbyAtmos: preferAtmos
		) else { return nil }
		print("[PLAYBACK] resolved \(track.title): direct stream, \(resolved.isDolbyAtmos ? "Dolby Atmos" : resolved.quality.rawValue)")
		return PlayableStream(
			url: resolved.url,
			quality: resolved.quality,
			isDolbyAtmos: resolved.isDolbyAtmos,
			isHiResStereo: false,
			hiResBitDepth: nil,
			hiResSampleRate: nil
		)
	}
}

/// The producer behind each route, so the resolver's walk can be exercised without a network.
struct PlaybackRouteResolver {
	var hiResStereo: () async -> PlayableStream?
	var dash: () async -> PlayableStream?
	var directStream: () async -> PlayableStream?

	func resolve(routes: [HiResStreamingRoute]) async -> PlayableStream? {
		for route in routes {
			let stream: PlayableStream?
			switch route {
			case .hiResStereo:
				stream = await hiResStereo()
			case .dash:
				stream = await dash()
			case .directStream:
				stream = await directStream()
			}
			if let stream { return stream }
		}
		return nil
	}
}

/// Routes a track through the hi-res stereo path: download the encrypted rendition,
/// decrypt it into a local cache, and hand the FLAC to AVPlayer.
public enum HiResStreaming {
	/// The desktop host the hi-res route lives on. Not `api.tidal.com`: the v1 host
	/// answers Atmos for these tracks and refuses the stereo `streamUrl` entirely.
	static let desktopAPILocation = "https://desktop.tidal.com/v1"

	/// Prunes the playback cache, keeping the prefetch window and the current track.
	public static func pruneCache(protecting trackIds: Set<Int> = []) {
		HiResStreamCache.pruneIfNeeded(protecting: trackIds)
	}

	static func isTrackCached(_ trackId: Int, quality: AudioQuality) -> Bool {
		HiResStreamCache.cachedFile(forTrackId: trackId, quality: quality) != nil
	}

	static func isDashTrackCached(_ trackId: Int, quality: AudioQuality) -> Bool {
		HiResStreamCache.cachedDashFile(forTrackId: trackId, quality: quality) != nil
	}

	public static func cacheUsageBytes() -> Int {
		HiResStreamCache.usageBytes()
	}

	/// Whether `track` should take the hi-res stereo route for this session.
	static func usesHiResStereo(for track: Track, session: Session, quality: AudioQuality, preferDolbyAtmos: Bool) -> Bool {
		HiResStreamingPolicy.usesHiResStereo(
			sessionHasHiResStereoAccess: session.hasHiResStereoAccess,
			preferDolbyAtmos: preferDolbyAtmos,
			trackHasStereo: track.hasStereo,
			trackHasDolbyAtmos: track.hasDolbyAtmos,
			quality: quality
		)
	}

	/// A playable, decrypted local file for `track` at `quality`, or nil when the route
	/// does not apply.
	static func playbackFile(for track: Track, session: Session, quality: AudioQuality) async -> HiResPlayback? {
		await playbackFile(for: track, session: session, quality: quality, cacheDirectory: HiResStreamCache.directory)
	}

	static func playbackFile(for track: Track, session: Session, quality: AudioQuality, cacheDirectory: URL) async -> HiResPlayback? {
		guard let url = await prepareFile(for: track, session: session, quality: quality, cacheDirectory: cacheDirectory) else {
			return nil
		}
		return describe(url)
	}

	/// Prepares whichever local-file route plays first for `track` at `quality`.
	static func prepareFile(for track: Track, session: Session, quality: AudioQuality) async -> URL? {
		guard let route = firstLocalRoute(for: track, session: session, quality: quality) else { return nil }
		switch route {
		case .hiResStereo:
			return await prepareFile(for: track, session: session, quality: quality, cacheDirectory: HiResStreamCache.directory)
		case .dash:
			return await dashPlaybackFile(for: track, session: session, quality: quality)?.url
		case .directStream:
			return nil
		}
	}

	/// The assembled DASH file for `track`, de-duplicated through the same in-flight
	/// table the hi-res route uses.
	static func dashPlaybackFile(for track: Track, session: Session, quality: AudioQuality) async -> DashPlayback? {
		guard let url = await HiResStreamPreparation.preparedFile(for: track.id, quality: quality, route: .dash, in: HiResStreamCache.directory, operation: {
			await DashAudio.playbackFile(for: track, session: session, preferredQuality: quality)?.url
		}) else {
			return nil
		}
		return DashAudio.describe(url)
	}

	/// The first route when it is a local-file route, or nil when the direct-stream
	/// route leads.
	static func firstLocalRoute(for track: Track, session: Session, quality: AudioQuality) -> HiResStreamingRoute? {
		let first = HiResStreamingPolicy.routes(
			sessionHasHiResStereoAccess: session.hasHiResStereoAccess,
			preferDolbyAtmos: false,
			trackHasStereo: track.hasStereo,
			trackHasDolbyAtmos: track.hasDolbyAtmos,
			quality: quality
		).first
		switch first {
		case .hiResStereo, .dash:
			return first
		default:
			return nil
		}
	}

	static func prepareFile(
		for track: Track,
		session: Session,
		quality: AudioQuality,
		cacheDirectory: URL
	) async -> URL? {
		guard firstLocalRoute(for: track, session: session, quality: quality) == .hiResStereo else {
			return nil
		}
		if let cached = HiResStreamCache.cachedFile(forTrackId: track.id, quality: quality, in: cacheDirectory) {
			HiResStreamCache.touch(cached)
			print("[PLAYBACK] hi-res stereo: reusing cached file for \(track.title)")
			return cached
		}
		return await HiResStreamPreparation.preparedFile(for: track.id, quality: quality, route: .hiResStereo, in: cacheDirectory) {
			await downloadFile(for: track, session: session, quality: quality, cacheDirectory: cacheDirectory)
		}
	}

	private static func downloadFile(for track: Track, session: Session, quality: AudioQuality, cacheDirectory: URL) async -> URL? {
		let resolution = await session.hiResStereoStream(trackId: track.id, audioQuality: quality)
		guard case .resolved(let manifest) = resolution else {
			if case .failed = resolution {
				print("[PLAYBACK] hi-res stereo: request failed for \(track.title), falling back")
			} else {
				print("[PLAYBACK] hi-res stereo: no stereo rendition for \(track.title), falling back")
			}
			return nil
		}
		// Reusing the download indicator keeps the play button from looking stalled during a 30 MB download.
		let status = session.helpers.downloadStatus
		status.startTask()
		defer { status.finishTask() }
		do {
			let destination = HiResStreamCache.fileURL(forTrackId: track.id, quality: quality, in: cacheDirectory)
			try await downloadAndDecrypt(manifest, to: destination)
			HiResStreamCache.writeFormatMetadata(bitDepth: manifest.bitDepth, sampleRate: manifest.sampleRate, for: destination)
			print("[PLAYBACK] hi-res stereo: decrypted \(track.title) to cache")
			return destination
		} catch {
			print("[PLAYBACK] hi-res stereo: failed for \(track.title): \(error), falling back")
			return nil
		}
	}

	/// Builds the prefetcher that prepares upcoming tracks for this session.
	/// `qualityProvider` is read per track, so a quality change needs no rebuild.
	public static func makePrefetcher(
		for session: Session,
		qualityProvider: @escaping () -> AudioQuality,
		shouldPrepare: @escaping (Track) -> Bool
	) -> HiResStreamPrefetcher {
		HiResStreamPrefetcher(
			depthProvider: { HiResStreamingPreferences.prefetchDepth },
			shouldPrepare: shouldPrepare,
			isCached: { isTrackCached($0.id, quality: qualityProvider()) || isDashTrackCached($0.id, quality: qualityProvider()) },
			prepare: { track in _ = await prepareFile(for: track, session: session, quality: qualityProvider()) },
			prune: { protected in pruneCache(protecting: protected) }
		)
	}

	/// The format of a local stream. The manifest's persisted values lead, because a
	/// FLAC file read reports no bit depth, with the file read as the fallback.
	nonisolated static func describe(_ url: URL) -> HiResPlayback {
		var bitDepth: Int?
		var sampleRate: Int?
		if let metadata = HiResStreamCache.readFormatMetadata(for: url) {
			bitDepth = metadata.bitDepth
			sampleRate = metadata.sampleRate
		}
		if let file = try? AVAudioFile(forReading: url) {
			sampleRate = sampleRate ?? Int(file.fileFormat.sampleRate)
			if bitDepth == nil {
				// `mBitsPerChannel` is 0 for FLAC, so only a positive value is real.
				let fileBits = Int(file.fileFormat.streamDescription.pointee.mBitsPerChannel)
				bitDepth = fileBits > 0 ? fileBits : nil
			}
		}
		return HiResPlayback(url: url, bitDepth: bitDepth, sampleRate: sampleRate)
	}

	/// Downloads the encrypted rendition and decrypts it into `destination`, so the
	/// bytes on disk are a playable FLAC and never the encrypted stream.
	///
	/// `@concurrent`: `nonisolated` alone is not enough — with `NonisolatedNonsendingByDefault`
	/// it would inherit the caller's main actor — so this is what moves the work off the
	/// UI thread.
	@concurrent
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

/// De-duplicates concurrent preparation of the same track.
enum HiResStreamPreparation {
	/// How long one preparation may run before it is abandoned; without this a stalled
	/// download-and-decrypt would block every later preparation for that track.
	static let timeout: Duration = .seconds(90)

	private static var inFlight: [String: Task<URL?, Never>] = [:]

	static func preparedFile(
		for trackId: Int,
		quality: AudioQuality,
		route: HiResStreamingRoute,
		in directory: URL,
		timeout: Duration = HiResStreamPreparation.timeout,
		operation: @escaping () async -> URL?
	) async -> URL? {
		// The quality and the route are part of the key: they produce different files
		// and must not share one task. The route follows the session's `cuk` capability,
		// so a login or logout cannot hand a hi-res file to a DASH caller.
		let key = "\(directory.path)#\(trackId)#\(quality.rawValue)#\(route.key)"
		if let existing = inFlight[key] {
			return await awaitResult(existing, timeout: timeout)
		}
		let task = Task { await operation() }
		inFlight[key] = task
		let result = await awaitResult(task, timeout: timeout)
		// Cleared by the creator even after a timeout, so a caller that gave up releases
		// the entry and a later preparation starts fresh.
		inFlight[key] = nil
		return result
	}

	/// Waits for `task` at most `timeout`; on timeout it is cancelled and `nil` returned.
	private static func awaitResult(_ task: Task<URL?, Never>, timeout: Duration) async -> URL? {
		let gate = PreparationResumeGate()
		return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
			Task {
				let result = await task.value
				if await gate.claim() { continuation.resume(returning: result) }
			}
			Task {
				try? await Task.sleep(for: timeout)
				if await gate.claim() {
					task.cancel()
					continuation.resume(returning: nil)
				}
			}
		}
	}
}

/// Lets exactly one of the two racers in `awaitResult` resume the continuation.
private actor PreparationResumeGate {
	private var claimed = false

	func claim() -> Bool {
		guard !claimed else { return false }
		claimed = true
		return true
	}
}

/// Which upcoming tracks to prepare. Pure, so the window can be tested directly.
enum HiResPrefetchPolicy {
	/// The tracks after `currentIndex`, in queue order, never wrapping, up to `depth`,
	/// skipping tracks the settings would not prepare and those already cached.
	static func upcomingTracks(
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

/// Prepares the tracks after the current one in the queue, one at a time, so a prepared
/// track starts instantly. It pauses after three skips in a row — browsing, not listening,
/// and those downloads are wasted — and resumes once a track has played for `settleInterval`.
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

	public func queueChanged(queue: [Track], currentIndex: Int) {
		self.queue = queue
		self.currentIndex = currentIndex
		pruneWindow()
		guard !isPausedForBrowsing else { return }
		startPreparing()
	}

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

	/// The window and the current track are exempt from eviction, since removing a file
	/// prepared for playback would defeat the point.
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

/// The local playback cache, at `~/Library/Caches/TidalSwift/stream/`. Never the offline
/// library: these files are a playback cache, not the user's music. The quality is in the
/// name because a Max file must never be served as Lossless or the badge would lie.
///
/// Bounded on launch and after every write: files not touched in a week are dropped, then
/// the least recently used until the directory is under the configured size.
nonisolated enum HiResStreamCache {
	static let maxAge: TimeInterval = 7 * 24 * 60 * 60

	static var directory: URL {
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		return base.appendingPathComponent("TidalSwift/stream", isDirectory: true)
	}

	static func fileURL(forTrackId trackId: Int, quality: AudioQuality, in directory: URL = HiResStreamCache.directory) -> URL {
		directory.appendingPathComponent("\(trackId)-\(quality.rawValue).flac")
	}

	static func cachedFile(forTrackId trackId: Int, quality: AudioQuality, in directory: URL = HiResStreamCache.directory) -> URL? {
		let url = fileURL(forTrackId: trackId, quality: quality, in: directory)
		return validatedCacheFile(at: url, magic: flacMagic, magicOffset: 0)
	}

	/// The DASH file's name differs by extension and quality.
	static func dashFileURL(forTrackId trackId: Int, quality: AudioQuality, in directory: URL = HiResStreamCache.directory) -> URL {
		directory.appendingPathComponent("\(trackId)-\(quality.rawValue).aac.m4a")
	}

	static func cachedDashFile(forTrackId trackId: Int, quality: AudioQuality, in directory: URL = HiResStreamCache.directory) -> URL? {
		let url = dashFileURL(forTrackId: trackId, quality: quality, in: directory)
		return validatedCacheFile(at: url, magic: mp4Magic, magicOffset: 4)
	}

	/// A decrypted FLAC starts with `fLaC`; an assembled AAC file carries the MP4
	/// `ftyp` box four bytes in.
	private static let flacMagic = Data("fLaC".utf8)
	private static let mp4Magic = Data("ftyp".utf8)
	/// A file shorter than this is a stub left by an interrupted download.
	private static let minimumCachedFileBytes = 512

	/// A cache file is trusted only when it looks complete: long enough to be a track and
	/// carrying its format's signature. Anything else is deleted and reported as a miss; a
	/// file that is not there is left alone, since deleting it would race an install.
	private static func validatedCacheFile(at url: URL, magic: Data, magicOffset: Int) -> URL? {
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		guard fileSize(at: url) >= minimumCachedFileBytes, hasMagic(at: url, magic: magic, offset: magicOffset) else {
			try? FileManager.default.removeItem(at: url)
			return nil
		}
		return url
	}

	private static func fileSize(at url: URL) -> Int {
		let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes?[.size] as? NSNumber)?.intValue ?? 0
	}

	private static func hasMagic(at url: URL, magic: Data, offset: Int) -> Bool {
		guard let handle = try? FileHandle(forReadingFrom: url),
		      let header = try? handle.read(upToCount: offset + magic.count) else { return false }
		try? handle.close()
		return header.count == offset + magic.count && header.subdata(in: offset..<(offset + magic.count)) == magic
	}

	/// The format a manifest reported for a cached file, persisted beside it.
	struct FormatMetadata: Codable {
		let bitDepth: Int?
		let sampleRate: Int?
	}

	static func metadataURL(for fileURL: URL) -> URL {
		fileURL.appendingPathExtension("json")
	}

	/// Records the manifest's format description next to `fileURL`; a stale sidecar is
	/// removed so a re-download cannot leave an old claim beside a new file.
	static func writeFormatMetadata(bitDepth: Int?, sampleRate: Int?, for fileURL: URL) {
		guard bitDepth != nil || sampleRate != nil else {
			try? FileManager.default.removeItem(at: metadataURL(for: fileURL))
			return
		}
		let metadata = FormatMetadata(bitDepth: bitDepth, sampleRate: sampleRate)
		guard let data = try? JSONEncoder().encode(metadata) else { return }
		try? data.write(to: metadataURL(for: fileURL))
	}

	static func readFormatMetadata(for fileURL: URL) -> FormatMetadata? {
		guard let data = try? Data(contentsOf: metadataURL(for: fileURL)) else { return nil }
		return try? JSONDecoder().decode(FormatMetadata.self, from: data)
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

	/// Marks a cache file as recently used, so LRU eviction keeps what plays.
	static func touch(_ url: URL, now: Date = Date()) {
		try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
	}

	static func pruneIfNeeded(protecting trackIds: Set<Int> = [], now: Date = Date()) {
		pruneIfNeeded(in: directory, protecting: trackIds, now: now)
	}

	static func pruneIfNeeded(in directory: URL, protecting trackIds: Set<Int> = [], now: Date = Date()) {
		prune(in: directory, maxBytes: HiResStreamingPreferences.cacheSizeBytes, maxAge: maxAge, protecting: trackIds, now: now)
	}

	/// Removes stale files first, then the least recently used until under the size cap.
	/// Protected tracks survive even when that leaves the directory over budget; the
	/// removed URLs are returned so a test can pin what went.
	@discardableResult
	static func prune(in directory: URL, maxBytes: Int, maxAge: TimeInterval, protecting trackIds: Set<Int> = [], now: Date = Date()) -> [URL] {
		let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
		guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
			return []
		}
		// The trailing dash keeps `<id>-` from matching a longer id's `<id0>-`.
		let protectedPrefixes = trackIds.map { "\($0)-" }
		let candidates: [(url: URL, date: Date, size: Int)] = contents.compactMap { url in
			guard !protectedPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }),
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
