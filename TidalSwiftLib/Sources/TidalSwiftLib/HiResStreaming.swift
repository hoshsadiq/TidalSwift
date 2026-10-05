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
/// The 24-bit stereo rendition is served only to a session whose token carries a
/// `cuk` claim, and only for a track that has a stereo rendition at all. It is
/// tried first, today's path second, so a track Tidal serves no stereo for
/// (Atmos-only) still plays, and a session without `cuk` never changes behaviour.
public enum HiResStreamingPolicy {
	public static func routes(
		sessionHasHiResStereoAccess: Bool,
		enabled: Bool,
		trackHasStereo: Bool
	) -> [HiResStreamingRoute] {
		if sessionHasHiResStereoAccess && enabled && trackHasStereo {
			return [.hiResStereo, .standard]
		}
		return [.standard]
	}

	/// Whether the first route is the hi-res one, for callers that only need that.
	public static func usesHiResStereo(
		sessionHasHiResStereoAccess: Bool,
		enabled: Bool,
		trackHasStereo: Bool
	) -> Bool {
		routes(
			sessionHasHiResStereoAccess: sessionHasHiResStereoAccess,
			enabled: enabled,
			trackHasStereo: trackHasStereo
		).first == .hiResStereo
	}
}

/// The hi-res stereo preference, owned by the library so the app target needs no
/// wiring beyond the toggle in `PreferencesView`, and the player can read it
/// without being handed a new value.
///
/// Default on: the route is tried first and falls back quietly, so a user who does
/// not want it opts out rather than in.
public enum HiResStreamingPreferences {
	public static let enabledKey = "hiResStereoEnabled"

	public static var isEnabled: Bool {
		UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
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

/// Routes a track through the hi-res stereo path for playback: resolve the
/// encrypted rendition, download it, decrypt it into a local cache, and hand that
/// file to AVPlayer. AVPlayer cannot read the encrypted stream, so the local file
/// is the whole point.
public enum HiResStreaming {
	/// The desktop host the hi-res route lives on. Not `api.tidal.com`: the v1 host
	/// answers Atmos for these tracks and refuses the stereo `streamUrl` entirely.
	static let desktopAPILocation = "https://desktop.tidal.com/v1"

	/// Prunes the playback cache. Called on launch, so a cache that grew while the
	/// app was closed is bounded before it is read.
	public static func pruneCache() {
		HiResStreamCache.pruneIfNeeded()
	}

	/// Whether `track`'s playback or download should take the hi-res stereo route for
	/// this session. The one place the capability, the preference and the track are
	/// read together.
	public static func usesHiResStereo(for track: Track, session: Session) -> Bool {
		HiResStreamingPolicy.usesHiResStereo(
			sessionHasHiResStereoAccess: session.hasHiResStereoAccess,
			enabled: HiResStreamingPreferences.isEnabled,
			trackHasStereo: track.hasStereo
		)
	}

	/// A playable, decrypted local file for `track`, or nil when the route does not
	/// apply or fails — in which case the caller uses today's path.
	public static func playbackFile(for track: Track, session: Session) async -> HiResPlayback? {
		await playbackFile(for: track, session: session, cacheDirectory: HiResStreamCache.directory)
	}

	static func playbackFile(for track: Track, session: Session, cacheDirectory: URL) async -> HiResPlayback? {
		guard usesHiResStereo(for: track, session: session) else {
			return nil
		}
		if let cached = HiResStreamCache.cachedFile(forTrackId: track.id, in: cacheDirectory) {
			print("[PLAYBACK] hi-res stereo: reusing cached file for \(track.title)")
			return describe(cached)
		}
		// TODO: Start sound sooner by prefetching on queue change or playing the
		// partially decrypted file. For a 31 MB rendition the local download plus
		// decrypt measured 2.8 s, before the network part; the play button waits that
		// long today, with the download indicator as the only feedback.
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
			HiResStreamCache.pruneIfNeeded(in: cacheDirectory)
			print("[PLAYBACK] hi-res stereo: decrypted \(track.title) to cache")
			return describe(destination)
		} catch {
			print("[PLAYBACK] hi-res stereo: failed for \(track.title): \(error), falling back")
			return nil
		}
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

/// The local cache for decrypted hi-res streams, at
/// `~/Library/Caches/TidalSwift/stream/`. Never the offline library: these files are
/// a playback cache, not the user's music. One file per track (`<id>.flac`), reused
/// on replay.
///
/// Bounded in two ways, applied on launch and after every write: files not touched
/// in a week are dropped, then the oldest are removed until the directory is under
/// 2 GiB (roughly an hour of 24-bit FLAC).
enum HiResStreamCache {
	static let maxBytes = 2 * 1024 * 1024 * 1024
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

	static func pruneIfNeeded(now: Date = Date()) {
		pruneIfNeeded(in: directory, now: now)
	}

	static func pruneIfNeeded(in directory: URL, now: Date = Date()) {
		prune(in: directory, maxBytes: maxBytes, maxAge: maxAge, now: now)
	}

	/// Removes stale files first, then the oldest until the directory is under the
	/// size cap. A file whose dates cannot be read is treated as old. Returns the
	/// removed URLs so a test can pin what went.
	@discardableResult
	static func prune(in directory: URL, maxBytes: Int, maxAge: TimeInterval, now: Date = Date()) -> [URL] {
		let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
		guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
			return []
		}
		let entries: [(url: URL, date: Date, size: Int)] = contents.compactMap { url in
			guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
			return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
		}
		var remaining = entries
		var removed: [URL] = []
		for entry in entries.sorted(by: { $0.date < $1.date }) where now.timeIntervalSince(entry.date) > maxAge {
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
