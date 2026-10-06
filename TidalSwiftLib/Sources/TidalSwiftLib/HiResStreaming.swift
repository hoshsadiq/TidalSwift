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
	/// Tidal's High/Low `playbackinfo` rendition: an unencrypted AAC MPD whose
	/// segments are assembled into a local file. The direct-stream route cannot play
	/// these tiers, so this is what plays them.
	case dash
	/// Today's path: the stereo `streamUrl` ladder, with the Atmos manifest fallback.
	/// The fallback the other routes fall through to when Tidal's desktop route cannot
	/// produce something playable.
	case directStream
}

/// Decides the route for a track, with no view, no storage and no session, so the
/// rule can be exercised directly — the same shape as `AudioQualityPolicy`.
///
/// The rule mirrors the official app: Tidal's own desktop `playbackinfo` route leads
/// at every tier, and the old direct-stream path is only the fallback for when that
/// route cannot produce something playable.
///
/// The rule, in order:
/// 1. The Atmos preference wins outright when the track has an Atmos rendition.
///    Atmos is only served by the direct-stream path, which asks for it explicitly.
/// 2. Otherwise Tidal's desktop route leads: the decrypted FLAC rendition at `Max`
///    and `Lossless`, the assembled DASH file at `High` and `Low`. The direct-stream
///    path stays behind it as the fallback for tracks it cannot play.
/// 3. A session without the `cuk` capability, the preference switched off, or a track
///    with no stereo rendition keeps the direct-stream path alone.
public enum HiResStreamingPolicy {
	public static func routes(
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

	/// Whether the first route is a local-file route — the decrypted FLAC rendition or
	/// the assembled DASH file — which is when preparing a track in advance is worth the
	/// bandwidth. The direct-stream path streams, so there is nothing to prepare.
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

	/// Whether the first route is the hi-res one, for callers that only need that.
	public static func usesHiResStereo(
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

/// The hi-res stereo preference, owned by the library so the app target needs no
/// wiring beyond the controls in `PreferencesView`, and the player can read them
/// without being handed new values.
///
/// Default on: the route is tried first and falls back quietly, so a user who does
/// not want it opts out rather than in.
public nonisolated enum HiResStreamingPreferences {
	public static let prefetchDepthKey = "hiResStreamPrefetchDepth"
	public static let cacheSizeBytesKey = "hiResStreamCacheBytes"

	/// How many tracks after the current one are prepared in advance. 0 turns
	/// preparing off; the setting is clamped to `prefetchDepthRange`.
	public static let defaultPrefetchDepth = 3
	public static let prefetchDepthRange = 0...15
	/// The choices offered in Preferences: off, then sizes that are easy to reason
	/// about rather than every number in the range.
	public static let prefetchDepthOptions: [Int] = [0, 1, 2, 3, 5, 8, 10, 15]

	public static var prefetchDepth: Int {
		guard UserDefaults.standard.object(forKey: prefetchDepthKey) != nil else {
			return defaultPrefetchDepth
		}
		return min(max(UserDefaults.standard.integer(forKey: prefetchDepthKey), prefetchDepthRange.lowerBound), prefetchDepthRange.upperBound)
	}

	/// How much disk space prepared tracks may use. The prefetch window and the track
	/// currently playing are exempt, so the cache can exceed this by a track or two.
	public static let defaultCacheBytes = 2 * 1024 * 1024 * 1024
	/// The budget is a free number of gigabytes in Preferences, bounded so a typo
	/// cannot set it to nothing or to the whole disk.
	public static let cacheSizeRange = 1...64

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
public nonisolated struct HiResPlayback {
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
	/// The sample rate of the decrypted rendition, for the badge. Read from the
	/// manifest, so it describes what Tidal served rather than what was asked for.
	public let hiResSampleRate: Int?
}

extension Session {
	/// Resolves the stream to play by walking the route policy in order: the first
	/// route that produces a stream wins.
	///
	/// `hiResStereo` yields a local, already-decrypted FLAC file, so a prepared track
	/// starts instantly. `dash` yields the local file assembled from Tidal's AAC
	/// segments, the route that plays a High/Low tier. `directStream` yields today's
	/// ladder result and is the fallback the others fall through to. The Atmos path is
	/// unchanged: it is the `directStream` route asked with the Atmos preference.
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
			hiResStereo: {
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
			},
			dash: {
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
			},
			directStream: {
				guard let resolved = await self.bestAudioUrl(
					trackId: track.id,
					preferredQuality: quality,
					preferDolbyAtmos: preferAtmosForTrack
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
		)
		return await resolver.resolve(routes: routes)
	}
}

/// The producer behind each route, so the resolver's walk — the first route whose
/// producer yields a stream wins — can be exercised without a network or a cache
/// on disk.
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

	/// Whether a track already has a prepared file in the cache at `quality`.
	public static func isTrackCached(_ trackId: Int, quality: AudioQuality) -> Bool {
		HiResStreamCache.cachedFile(forTrackId: trackId, quality: quality) != nil
	}

	/// Whether a track already has an assembled DASH file in the cache at `quality`.
	public static func isDashTrackCached(_ trackId: Int, quality: AudioQuality) -> Bool {
		HiResStreamCache.cachedDashFile(forTrackId: trackId, quality: quality) != nil
	}

	/// How much disk space the prepared-track cache currently uses.
	public static func cacheUsageBytes() -> Int {
		HiResStreamCache.usageBytes()
	}

	/// Whether `track` should take the hi-res stereo route for this session and quality.
	/// The quality decides the route: `High`/`Max` lead with the decrypted FLAC rendition,
	/// `Medium`/`Low` with the DASH assembly, so a caller that passes the quality it is
	/// actually downloading at gets the route that quality plays. The offline wish and
	/// the offline sync pass `config.offlineAudioQuality`; a manual download passes the
	/// quality the user asked for.
	public static func usesHiResStereo(for track: Track, session: Session, quality: AudioQuality) -> Bool {
		HiResStreamingPolicy.usesHiResStereo(
			sessionHasHiResStereoAccess: session.hasHiResStereoAccess,
			preferDolbyAtmos: false,
			trackHasStereo: track.hasStereo,
			trackHasDolbyAtmos: track.hasDolbyAtmos,
			quality: quality
		)
	}

	/// A playable, decrypted local file for `track` at `quality`, or nil when the route
	/// does not apply or fails — in which case the caller falls through to the next
	/// route.
	public static func playbackFile(for track: Track, session: Session, quality: AudioQuality) async -> HiResPlayback? {
		await playbackFile(for: track, session: session, quality: quality, cacheDirectory: HiResStreamCache.directory)
	}

	static func playbackFile(for track: Track, session: Session, quality: AudioQuality, cacheDirectory: URL) async -> HiResPlayback? {
		guard let url = await prepareFile(for: track, session: session, quality: quality, cacheDirectory: cacheDirectory) else {
			return nil
		}
		return describe(url)
	}

	/// Prepares whichever local-file route plays first for `track` at `quality`,
	/// mirroring `playableStream`: the decrypted FLAC rendition or the assembled DASH
	/// file. De-duplicated per track, so a play that arrives while the prefetcher is
	/// already preparing the same track waits for that work rather than downloading
	/// twice. The prefetcher uses this so a queue is prepared at any tier; the
	/// direct-stream route streams, so there is nothing to prepare.
	public static func prepareFile(for track: Track, session: Session, quality: AudioQuality) async -> URL? {
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

	/// The assembled DASH file for `track`, de-duplicated per track and quality through
	/// the same in-flight table the hi-res route uses. The play path and the prefetcher
	/// both come through here, so a play that arrives while the prefetcher is assembling
	/// the same track waits for that work instead of fetching the manifest and every
	/// segment a second time.
	static func dashPlaybackFile(for track: Track, session: Session, quality: AudioQuality) async -> DashPlayback? {
		guard let url = await HiResStreamPreparation.preparedFile(for: track.id, quality: quality, in: HiResStreamCache.directory, operation: {
			await DashAudio.playbackFile(for: track, session: session, preferredQuality: quality)?.url
		}) else {
			return nil
		}
		return DashAudio.describe(url)
	}

	/// The first route when it is a local-file route (hi-res stereo or DASH), or nil
	/// when the direct-stream route leads. Shared by the prefetcher's preparation and
	/// its cache check.
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
		return await HiResStreamPreparation.preparedFile(for: track.id, quality: quality, in: cacheDirectory) {
			await downloadFile(for: track, session: session, quality: quality, cacheDirectory: cacheDirectory)
		}
	}

	private static func downloadFile(for track: Track, session: Session, quality: AudioQuality, cacheDirectory: URL) async -> URL? {
		guard case .resolved(let manifest) = await session.hiResStereoStream(trackId: track.id, audioQuality: quality) else {
			print("[PLAYBACK] hi-res stereo: no stereo rendition for \(track.title), falling back")
			return nil
		}
		// The download indicator already exists; reusing it keeps the play button
		// from looking stalled while a 30 MB rendition downloads and decrypts.
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
	/// `qualityProvider` is read per track, so a quality change is followed without
	/// rebuilding the prefetcher.
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

	/// The format of a local stream. The manifest's persisted values lead — a FLAC
	/// file read reports no bit depth, and the manifest knows what Tidal served — with
	/// the file read as the fallback for anything without them. A file that does not
	/// open still plays but is described without a bit depth rather than guessed at.
	///
	/// `nonisolated`: a pure file read, so preparing a track off the main actor can
	/// describe what it produced without hopping back to the UI thread.
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
	/// `@concurrent`: the download and the decrypt are the seconds of work that used
	/// to run on the main actor and freeze the window on every track switch. Nothing
	/// here touches UI or observable state, so it runs on the concurrent executor
	/// instead; the caller reports progress around it.
	///
	/// `nonisolated` alone is not enough here: with `NonisolatedNonsendingByDefault`
	/// it would inherit the caller's main actor, so the work still lands on the UI
	/// thread. `@concurrent` is what moves it off.
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

/// De-duplicates concurrent preparation of the same track. A play that arrives while
/// the prefetcher is already fetching that track awaits the same work instead of
/// starting a second download.
enum HiResStreamPreparation {
	private static var inFlight: [String: Task<URL?, Never>] = [:]

	static func preparedFile(
		for trackId: Int,
		quality: AudioQuality,
		in directory: URL,
		operation: @escaping () async -> URL?
	) async -> URL? {
		// The quality is part of the key: two preparations of the same track at
		// different qualities produce different files and must not share one task.
		let key = "\(directory.path)#\(trackId)#\(quality.rawValue)"
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

/// The local playback cache, at `~/Library/Caches/TidalSwift/stream/`. Never the
/// offline library: these files are a playback cache, not the user's music. One file
/// per track, route and quality, reused on replay: decrypted hi-res stereo
/// (`<id>-<quality>.flac`) and the assembled DASH AAC file (`<id>-<quality>.aac.m4a`)
/// share this directory, so they share one budget rather than competing with two.
/// The quality is in the name because the same track at two tiers is two different
/// files; a Max file must never be served as Lossless or the badge would lie.
///
/// A hi-res file also carries a small `<name>.json` sidecar holding the format the
/// manifest reported, because a FLAC file read cannot report its own bit depth.
///
/// Bounded in two ways, applied on launch and after every write: files not touched
/// in a week are dropped, then the least recently used — of either kind — are removed
/// until the directory is under the configured size. A file is touched when it is
/// played, so eviction keeps the tracks that actually get listened to.
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

	/// The assembled DASH file's name differs from the hi-res one by extension and by
	/// quality, so a track cached at one route or tier does not masquerade as another.
	static func dashFileURL(forTrackId trackId: Int, quality: AudioQuality, in directory: URL = HiResStreamCache.directory) -> URL {
		directory.appendingPathComponent("\(trackId)-\(quality.rawValue).aac.m4a")
	}

	static func cachedDashFile(forTrackId trackId: Int, quality: AudioQuality, in directory: URL = HiResStreamCache.directory) -> URL? {
		let url = dashFileURL(forTrackId: trackId, quality: quality, in: directory)
		return validatedCacheFile(at: url, magic: mp4Magic, magicOffset: 4)
	}

	/// A decrypted FLAC starts with `fLaC`; an assembled AAC file carries the MP4
	/// `ftyp` box four bytes in. A file whose signature is missing was not written by
	/// this app.
	private static let flacMagic = Data("fLaC".utf8)
	private static let mp4Magic = Data("ftyp".utf8)
	/// A file shorter than this is a stub left by an interrupted download, whatever its
	/// header claims; no real track is this small.
	private static let minimumCachedFileBytes = 512

	/// A cache file is trusted only when it looks complete: long enough to be a track and
	/// carrying its format's signature. A file that fails either check — a download
	/// interrupted before its tail, or a stale stub — is deleted and reported as a miss,
	/// so the next play re-downloads instead of serving a truncated file forever.
	private static func validatedCacheFile(at url: URL, magic: Data, magicOffset: Int) -> URL? {
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

	/// The format a manifest reported for a cached file, persisted beside it so a
	/// relaunch reads it back without the network. `nil` when nothing was recorded.
	struct FormatMetadata: Codable {
		let bitDepth: Int?
		let sampleRate: Int?
	}

	static func metadataURL(for fileURL: URL) -> URL {
		fileURL.appendingPathExtension("json")
	}

	/// Records the manifest's format description next to `fileURL`. Nothing is written
	/// when there is nothing to record, and a stale sidecar is removed so a re-download
	/// cannot leave an old claim beside a new file.
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
	/// Protected tracks are skipped entirely — every file whose name starts with the
	/// track's `<id>-` prefix, whichever route, quality or sidecar — so the prefetch
	/// window and the current track survive even when that leaves the directory over
	/// budget. Returns the removed URLs so a test can pin what went.
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
