//
//  PlaybackRouting.swift
//  TidalSwiftLib
//

import Foundation

/// Which path a track's playback takes, in the order to try.
enum PlaybackRoute: Equatable {
	/// Tidal's HLS manifest: the playlist hands AVPlayer the variant it names, so the
	/// track starts without waiting; the same playlist is written to the cache behind it.
	/// Every stereo tier is served this way.
	case hls
	/// The stereo `streamUrl` ladder with the Atmos fallback, and the fall-through route.
	case directStream
}

/// Decides the route for a track, with no view, no storage and no session, so the
/// rule can be exercised directly.
///
/// Tidal's HLS manifest leads a play whenever the session has desktop playback access, and the
/// direct-stream path is the fallback. HLS is not gated on the advertised modes (the catalogue
/// omits STEREO for tracks the manifest still serves FLAC for) and the Atmos preference is not
/// a route: it only reorders the HLS rungs (`HLSStreaming.rungs`), so it can never be the
/// reason a track has no route. The desktop `cuk` claim is the only gate.
public enum PlaybackRoutingPolicy {
	/// The ladder a play walks: HLS leads, so a track starts from the playlist before its file
	/// is written, then the direct stream.
	static func routes(sessionHasDesktopPlaybackAccess: Bool) -> [PlaybackRoute] {
		guard sessionHasDesktopPlaybackAccess else { return [.directStream] }
		return [.hls, .directStream]
	}

	/// Whether HLS serves this track, which is also the prefetcher's eligibility and the
	/// offline sync's source: when it is false the track falls back to the direct stream.
	/// The desktop `cuk` claim is the gate; the advertised modes and the Atmos preference are not.
	public static func usesHLS(sessionHasDesktopPlaybackAccess: Bool) -> Bool {
		routes(sessionHasDesktopPlaybackAccess: sessionHasDesktopPlaybackAccess).first == .hls
	}
}

extension Session {
	/// Whether this session can use Tidal's desktop playback route, the HLS manifest.
	///
	/// The signal is the `cuk` (client unique key) claim in the access token; Tidal answers
	/// the desktop endpoints with Atmos instead when it is absent, and wraps the manifest in
	/// FairPlay for a device client. The claim is read from the token itself rather than
	/// stored, since it is a small payload read once per play.
	///
	/// - Complexity: O(*n*) in the length of the access token.
	public var hasDesktopPlaybackAccess: Bool {
		DesktopSessionAccess.hasDesktopClaim(in: config.accessToken)
	}
}

enum DesktopSessionAccess {
	/// Reads a `cuk` claim out of a JWT access token; the signature is not checked.
	static func hasDesktopClaim(in accessToken: String) -> Bool {
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

/// The stream resolved for a track, whichever route produced it. `Player` plays `url`.
public struct PlayableStream {
	public let url: URL
	public let quality: AudioQuality
	public let isDolbyAtmos: Bool
	/// The rate a cached file or the loaded item reports; a playlist carries none, so this
	/// is nil until the player has loaded the stream.
	public let sampleRate: Int?
	/// The stream came from Tidal's HLS manifest; the badge is read from the tier that
	/// served it (never the tier that was asked for), since the stream itself reports no
	/// bit depth.
	public let isHLS: Bool

	public init(
		url: URL,
		quality: AudioQuality,
		isDolbyAtmos: Bool,
		sampleRate: Int? = nil,
		isHLS: Bool = false
	) {
		self.url = url
		self.quality = quality
		self.isDolbyAtmos = isDolbyAtmos
		self.sampleRate = sampleRate
		self.isHLS = isHLS
	}
}

extension Session {
	/// Resolves the stream to play by walking the route policy in order: the first
	/// route that produces a stream wins.
	public func playableStream(
		for track: Track,
		quality: AudioQuality,
		preferDolbyAtmos: Bool,
		protecting: Set<Int> = [],
		queueTrackIds: Set<Int> = []
	) async -> PlayableStream? {
		let preferAtmosForTrack = track.hasDolbyAtmos && preferDolbyAtmos
		let routes = PlaybackRoutingPolicy.routes(sessionHasDesktopPlaybackAccess: hasDesktopPlaybackAccess)
		let resolver = PlaybackRouteResolver(
			hls: { await self.hlsPlayableStream(for: track, quality: quality, preferDolbyAtmos: preferAtmosForTrack, protecting: protecting, queueTrackIds: queueTrackIds) },
			directStream: { await self.directPlayableStream(for: track, quality: quality, preferAtmos: preferAtmosForTrack) }
		)
		return await resolver.resolve(routes: routes)
	}

	private func hlsPlayableStream(
		for track: Track,
		quality: AudioQuality,
		preferDolbyAtmos: Bool,
		protecting: Set<Int>,
		queueTrackIds: Set<Int>
	) async -> PlayableStream? {
		guard let source = await HLSStreaming.playbackSource(
			for: track,
			session: self,
			quality: quality,
			preferDolbyAtmos: preferDolbyAtmos,
			protecting: protecting,
			queueTrackIds: queueTrackIds
		) else { return nil }
		print("[PLAYBACK] resolved \(track.title): hls, \(source.rung.format)")
		return PlayableStream(
			url: source.url,
			quality: source.rung.quality ?? quality,
			isDolbyAtmos: source.rung.isDolbyAtmos,
			sampleRate: source.sampleRate,
			isHLS: true
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
			isDolbyAtmos: resolved.isDolbyAtmos
		)
	}
}

/// The producer behind each route, so the resolver's walk can be exercised without a network.
struct PlaybackRouteResolver {
	var hls: () async -> PlayableStream? = { nil }
	var directStream: () async -> PlayableStream?

	func resolve(routes: [PlaybackRoute]) async -> PlayableStream? {
		for route in routes {
			let stream: PlayableStream?
			switch route {
			case .hls:
				stream = await hls()
			case .directStream:
				stream = await directStream()
			}
			if let stream { return stream }
		}
		return nil
	}
}

/// Which upcoming tracks to prepare. Pure, so the window can be tested directly.
enum PlaybackPrefetchPolicy {
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
public final class PlaybackPrefetcher {
	public static let browseSkipThreshold = 3

	private let settleInterval: TimeInterval
	private let depthProvider: () -> Int
	private let shouldPrepare: (Track) -> Bool
	private let isCached: (Track) -> Bool
	private let prepare: (Track, Set<Int>, Set<Int>) async -> Void
	private let prune: (Set<Int>, Set<Int>) -> Void

	private var queue: [Track] = []
	private var currentIndex = 0
	private var runTask: Task<Void, Never>?
	private var resumeTask: Task<Void, Never>?
	private var consecutiveSkips = 0
	public private(set) var isPausedForBrowsing = false

	/// Builds the prefetcher that prepares upcoming tracks for this session.
	/// `qualityProvider` is read per track, so a quality change needs no rebuild.
	///
	/// Preparing is the play path's own HLS cache write, so a prefetched track is exactly a
	/// cached track and `isCached` answers from the same place the play does. The remaining
	/// parameters are seams for a test; production reads the settings and the real cache.
	public static func make(
		for session: Session,
		qualityProvider: @escaping () -> AudioQuality,
		preferDolbyAtmosProvider: @escaping () -> Bool = { false },
		shouldPrepare: @escaping (Track) -> Bool,
		depthProvider: @escaping () -> Int = { PlaybackCachePreferences.prefetchDepth },
		cacheDirectory: URL? = nil,
		resolvePlaylist: ((Int, HLSRung) async throws -> URL)? = nil,
		fetch: HLSStreaming.ResourceFetcher? = nil
	) -> PlaybackPrefetcher {
		let cacheDirectory = cacheDirectory ?? PlaybackCache.directory
		return PlaybackPrefetcher(
			depthProvider: depthProvider,
			shouldPrepare: shouldPrepare,
			isCached: { track in
				PlaybackCache.cachedFile(forTrackId: track.id, rungs: HLSStreaming.rungs(
					for: qualityProvider(),
					preferDolbyAtmos: preferDolbyAtmosProvider(),
					trackHasDolbyAtmos: track.hasDolbyAtmos
				), in: cacheDirectory) != nil
			},
			prepare: { track, protecting, queueTrackIds in
				_ = await HLSStreaming.playbackFile(
					for: track,
					session: session,
					quality: qualityProvider(),
					preferDolbyAtmos: preferDolbyAtmosProvider(),
					cacheDirectory: cacheDirectory,
					protecting: protecting,
					queueTrackIds: queueTrackIds,
					resolvePlaylist: resolvePlaylist,
					fetch: fetch
				)
			},
			prune: { protected, queue in PlaybackCache.pruneIfNeeded(in: cacheDirectory, protecting: protected, queueTrackIds: queue) }
		)
	}

	init(
		settleInterval: TimeInterval = 30,
		depthProvider: @escaping () -> Int,
		shouldPrepare: @escaping (Track) -> Bool = { _ in true },
		isCached: @escaping (Track) -> Bool = { _ in false },
		prepare: @escaping (Track, Set<Int>, Set<Int>) async -> Void,
		prune: @escaping (Set<Int>, Set<Int>) -> Void = { _, _ in }
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
		let window = PlaybackPrefetchPolicy.upcomingTracks(
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
				let protection = self.protection()
				await self.prepare(track, protection.protecting, protection.queueTrackIds)
				self.pruneWindow()
			}
		}
	}

	/// The window and the current track are exempt from eviction, since removing a file
	/// prepared for playback would defeat the point.
	private func pruneWindow() {
		let protection = protection()
		prune(protection.protecting, protection.queueTrackIds)
	}

	/// What the cache must not evict right now: the current track and the prefetch window,
	/// plus every track in the queue. The play path's own cache write prunes under the same
	/// protection, so a play never evicts what is playing or about to play.
	public func cacheProtection() -> (protecting: Set<Int>, queueTrackIds: Set<Int>) {
		protection()
	}

	private func protection() -> (protecting: Set<Int>, queueTrackIds: Set<Int>) {
		var protecting = Set(PlaybackPrefetchPolicy.upcomingTracks(
			queue: queue,
			currentIndex: currentIndex,
			depth: depthProvider(),
			shouldPrepare: shouldPrepare,
			isCached: { _ in false }
		).map(\.id))
		if queue.indices.contains(currentIndex) {
			protecting.insert(queue[currentIndex].id)
		}
		return (protecting, Set(queue.map(\.id)))
	}
}
