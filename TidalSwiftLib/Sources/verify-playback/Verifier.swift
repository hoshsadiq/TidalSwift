//
//  Verifier.swift
//  verify-playback
//
//  For each track and each combination of settings, resolve through the app's own playback
//  path, decode the served audio, and print EXPECTED vs DECIDED vs MEASURED with a verdict.
//

import AVFoundation
import Foundation
import TidalSwiftLib

/// One combination of settings to run: a path, a ceiling, and the Atmos preference.
struct Combination {
	enum Path: String {
		case stream
		case offline
	}

	let path: Path
	let ceiling: Tier
	let atmos: Bool
}

/// EXPECTED — from the hand-written rules (`Expectations`).
struct Expected {
	let rungs: [String]
	let atmosAdmitted: Bool
	let served: String
	let badge: String
}

/// DECIDED — what the library chose, read from the library itself.
struct Decided {
	let route: [String]
	let rungs: [String]
	let file: String?
	let served: String?
	let badgeRung: String?
}

/// MEASURED — what was asked, what TIDAL answered, and what the bytes hold.
struct Measured {
	let asked: String?
	let answered: String?
	let decoded: DecodedFacts?
}

/// One reported combination.
struct Result {
	let trackId: Int
	let kind: TrackKind
	let hiRes: Bool
	let combination: Combination
	let expected: Expected
	let decided: Decided
	let measured: Measured
	let rung: HLSRung?
}

/// A resolved file and the rendition it holds.
struct Resolved {
	let file: URL
	let rung: HLSRung
}

struct Verifier {
	let options: Options
	let session: Session
	let assemblyDirectory: URL
	let directDirectory: URL
	let offlineLibraryDirectory: URL
	let offlineTimeout: TimeInterval = 120

	// MARK: - Entry

	static func run(options: Options) async -> Int {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("verify-playback-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let offlineRoot = root.appendingPathComponent("offline")
		let offlineSuiteName = "verify-playback-\(UUID().uuidString)"
		defer {
			try? FileManager.default.removeItem(at: root)
			UserDefaults().removePersistentDomain(forName: offlineSuiteName)
		}

		switch loadSession(options: options, offlineRoot: offlineRoot, offlineSuiteName: offlineSuiteName) {
		case .notLoggedIn(let message):
			print(message)
			return 1
		case .ready(let session, let source):
			if let source { print("session: \(source)") }
			let verifier = Verifier(
				options: options,
				session: session,
				assemblyDirectory: root.appendingPathComponent("assembly"),
				directDirectory: root.appendingPathComponent("direct"),
				offlineLibraryDirectory: offlineRoot.appendingPathComponent("TidalSwift Offline Library")
			)
			return await verifier.report()
		}
	}

	private enum SessionSource: CustomStringConvertible {
		case stored
		case environmentToken

		var description: String {
			switch self {
			case .stored:
				return "the app's stored login"
			case .environmentToken:
				return "TIDAL_TEST_TOKEN"
			}
		}
	}

	private enum SessionLoad {
		case ready(Session, SessionSource?)
		case notLoggedIn(String)
	}

	/// Reads the session the way the app stores it, through the tool's own reader of the app's
	/// defaults domain (a command line tool's `UserDefaults.standard` is its own domain, not the
	/// app's). A `TIDAL_TEST_TOKEN` in the environment wins, for a run on a machine whose stored
	/// login has lapsed. A missing or expired stored session yields one clear line, never a guess
	/// or a crash. A fixture run needs no login: the fixture seam answers the manifest request, so
	/// no request is made.
	private static func loadSession(options: Options, offlineRoot: URL, offlineSuiteName: String) -> SessionLoad {
		if options.fixtureDirectory != nil {
			let config = Config(accessToken: Fixture.desktopAccessToken, refreshToken: "", clientID: "", offlineAudioQuality: .max)
			return .ready(makeSession(config: config, offlineRoot: offlineRoot, offlineSuiteName: offlineSuiteName), nil)
		}
		if let token = ProcessInfo.processInfo.environment["TIDAL_TEST_TOKEN"], !token.isEmpty {
			let config = Config(accessToken: token, refreshToken: "", clientID: "", offlineAudioQuality: .max)
			let session = makeSession(config: config, offlineRoot: offlineRoot, offlineSuiteName: offlineSuiteName)
			// The catalogue endpoints need the stored session's user; best effort, since a machine
			// whose login lapsed may still hold the session information.
			if let stored = UserDefaults(suiteName: StoredSession.appDefaultsDomain) {
				StoredSession.apply(to: session, from: stored)
			}
			return .ready(session, .environmentToken)
		}
		guard let defaults = UserDefaults(suiteName: StoredSession.appDefaultsDomain) else {
			return .notLoggedIn("no stored session: log in through the TidalSwift app, then run this again")
		}
		switch StoredSession.config(from: defaults) {
		case .missing:
			return .notLoggedIn("no stored session: log in through the TidalSwift app, then run this again")
		case .expired:
			return .notLoggedIn("the stored session is missing or expired: log in through the TidalSwift app, then run this again")
		case .stored(let config):
			let session = makeSession(config: config, offlineRoot: offlineRoot, offlineSuiteName: offlineSuiteName)
			StoredSession.apply(to: session, from: defaults)
			return .ready(session, .stored)
		}
	}

	/// Builds the session with a temporary offline library, and redirects the offline
	/// preferences to a private suite, so the developer's real library and settings are never
	/// read or written. The redirect happens before any await, so the launch sync the offline
	/// manager starts cannot read the real domain first.
	private static func makeSession(config: Config, offlineRoot: URL, offlineSuiteName: String) -> Session {
		let session = Session(config: config, offlineLibraryRoot: offlineRoot)
		session.helpers.offline.defaults = UserDefaults(suiteName: offlineSuiteName) ?? .standard
		return session
	}

	// MARK: - Combinations

	/// The combinations to run. `--matrix` widens an unset ceiling to every tier and an unset
	/// Atmos preference to both; otherwise the named values are used as given.
	private func combinations() -> [Combination] {
		if options.offline {
			let ceilings = options.downloadCeilings.isEmpty
				? (options.matrix ? Tier.allCases : [Tier.of(session.config.offlineAudioQuality)])
				: options.downloadCeilings
			return sweep(.offline, ceilings)
		}
		let ceilings = options.streamCeilings.isEmpty ? Tier.allCases : options.streamCeilings
		return sweep(.stream, ceilings)
	}

	private func sweep(_ path: Combination.Path, _ ceilings: [Tier]) -> [Combination] {
		let atmosValues = options.matrix && !options.atmosGiven ? [true, false] : [options.atmos]
		return ceilings.flatMap { ceiling in
			atmosValues.map { Combination(path: path, ceiling: ceiling, atmos: $0) }
		}
	}

	// MARK: - Report

	private func report() async -> Int {
		print()
		print(Self.preamble)

		var results: [Result] = []
		var everyTrackReadable = true
		for trackId in options.trackIds {
			let track: Track
			if options.fixtureDirectory != nil {
				guard let fixtureTrack = Fixture.track(id: trackId) else {
					print("track \(trackId): the fixture track could not be built; skipping")
					everyTrackReadable = false
					continue
				}
				track = fixtureTrack
			} else if let fetched = await session.track(trackId: trackId) {
				track = fetched
			} else {
				print("track \(trackId): could not be read from the catalogue; skipping")
				everyTrackReadable = false
				continue
			}
			if options.offline {
				print("offline: downloading through the app's sync into a temporary library; your real ~/Music/TidalSwift Offline Library is untouched")
			}
			for combination in combinations() {
				results.append(await run(track: track, combination: combination))
			}
		}

		print()
		for result in results {
			print(Self.block(result))
		}
		print()
		print(Self.summary(results))
		return everyTrackReadable ? 0 : 1
	}

	/// Runs one combination through all three layers.
	private func run(track: Track, combination: Combination) async -> Result {
		let kind = TrackKind.of(track)
		let hiRes = track.mediaMetadata?.tags.contains("HIRES_LOSSLESS") ?? false
		let served = Expectations.servedRendition(
			at: combination.ceiling,
			atmos: combination.atmos,
			kind: kind,
			hiRes: hiRes
		)
		let expected = Expected(
			rungs: Expectations.rungs(at: combination.ceiling, atmos: combination.atmos, kind: kind),
			atmosAdmitted: Expectations.atmosAdmitted(at: combination.ceiling),
			served: served,
			badge: Expectations.badge(forRendition: served)
		)

		let resolved: Resolved?
		switch combination.path {
		case .stream:
			resolved = await streamResolve(track: track, combination: combination)
		case .offline:
			resolved = await offlineResolve(track: track, combination: combination)
		}

		let decoded: DecodedFacts?
		if let resolved {
			decoded = await AudioDecoder.decode(resolved.file)
		} else {
			decoded = nil
		}

		let decided = Self.decided(track: track, combination: combination, session: session, resolved: resolved)
		let measured = Self.measured(track: track, combination: combination, resolved: resolved, decoded: decoded)
		return Result(
			trackId: track.id,
			kind: kind,
			hiRes: hiRes,
			combination: combination,
			expected: expected,
			decided: decided,
			measured: measured,
			rung: resolved?.rung
		)
	}

	/// DECIDED — the library's own choices, read from its public surface: the route list, the
	/// rung order, the file it chose, and the rung the badge is built from.
	private static func decided(track: Track, combination: Combination, session: Session, resolved: Resolved?) -> Decided {
		let route = PlaybackRoutingPolicy
			.routes(sessionHasDesktopPlaybackAccess: session.hasDesktopPlaybackAccess)
			.map { $0 == .hls ? "hls" : "directStream" }
		let rungs = HLSStreaming.rungs(
			for: combination.ceiling.quality,
			preferDolbyAtmos: combination.atmos,
			trackHasDolbyAtmos: track.hasDolbyAtmos
		).map(\.format)
		let rendition = resolved.map { Expectations.rendition(of: $0.rung) }
		return Decided(
			route: route,
			rungs: rungs,
			file: resolved?.file.lastPathComponent,
			served: rendition,
			badgeRung: rendition
		)
	}

	/// MEASURED — what the tool asked the endpoint for, what TIDAL answered, and the decoded
	/// facts. No `AVPlayer` is created, so nothing plays.
	private static func measured(track: Track, combination: Combination, resolved: Resolved?, decoded: DecodedFacts?) -> Measured {
		let firstRung = HLSStreaming.rungs(
			for: combination.ceiling.quality,
			preferDolbyAtmos: combination.atmos,
			trackHasDolbyAtmos: track.hasDolbyAtmos
		).first?.format
		return Measured(
			asked: firstRung,
			answered: resolved?.rung.format,
			decoded: decoded
		)
	}

	// MARK: - Streaming resolve

	/// The production resolve for one combination: the route policy walks Tidal's HLS manifest
	/// first and the direct stream second, exactly as the player does. A non-nil
	/// `resolvePlaylist` is the fixture seam, which forces the HLS path and makes no request.
	private func streamResolve(track: Track, combination: Combination) async -> Resolved? {
		let resolvePlaylist: ((Int, HLSRung) async throws -> URL)? = options.fixtureDirectory.map { fixture in
			Fixture.resolver(multivariantURL: fixture.appendingPathComponent("master.m3u8"))
		}
		let preferAtmos = combination.atmos
		// One cache directory per track, ceiling and preference: the cache serves any rung on a
		// ceiling's ladder, so a shared directory would let one combination's cached file answer
		// the next combination's request and hide what that combination actually serves.
		let cacheDirectory = assemblyDirectory.appendingPathComponent(
			"\(track.id)-\(combination.ceiling.rawValue)-\(preferAtmos ? "atmos" : "stereo")", isDirectory: true
		)

		if resolvePlaylist != nil {
			return await hlsResolve(track: track, ceiling: combination.ceiling, preferAtmos: preferAtmos, cacheDirectory: cacheDirectory, resolvePlaylist: resolvePlaylist)
		}
		if PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: session.hasDesktopPlaybackAccess),
		   let resolved = await hlsResolve(track: track, ceiling: combination.ceiling, preferAtmos: preferAtmos, cacheDirectory: cacheDirectory, resolvePlaylist: nil) {
			return resolved
		}
		return await directResolve(track: track, ceiling: combination.ceiling, preferAtmos: preferAtmos)
	}

	/// The player's own entry: it hands back the playlist and starts the same cache write
	/// behind it. The tool waits for that write, since it needs the assembled file to decode.
	private func hlsResolve(
		track: Track,
		ceiling: Tier,
		preferAtmos: Bool,
		cacheDirectory: URL,
		resolvePlaylist: ((Int, HLSRung) async throws -> URL)?
	) async -> Resolved? {
		guard let source = await HLSStreaming.playbackSource(
			for: track,
			session: session,
			quality: ceiling.quality,
			preferDolbyAtmos: preferAtmos,
			cacheDirectory: cacheDirectory,
			resolvePlaylist: resolvePlaylist
		) else { return nil }

		let file: URL?
		if let download = source.backgroundDownload {
			file = await download.value
		} else {
			file = source.url
		}
		guard let file else { return nil }
		return Resolved(file: file, rung: source.rung)
	}

	/// The fallback route the player takes when HLS cannot serve the track: the direct
	/// `streamUrl` ladder. Its bytes are fetched here the same way `Network.download` fetches
	/// them for the offline sync — a plain GET to a pre-signed URL.
	private func directResolve(track: Track, ceiling: Tier, preferAtmos: Bool) async -> Resolved? {
		guard let resolved = await session.bestAudioUrl(
			trackId: track.id,
			preferredQuality: ceiling.quality,
			preferDolbyAtmos: preferAtmos
		) else { return nil }
		let extensionPart = resolved.url.pathExtension.isEmpty ? "bin" : resolved.url.pathExtension
		let destination = directDirectory.appendingPathComponent("\(track.id)-\(ceiling.rawValue).\(extensionPart)")
		do {
			try await Self.download(resolved.url, to: destination)
		} catch {
			return nil
		}
		let rung: HLSRung = resolved.isDolbyAtmos ? .dolbyAtmos : .stereo(resolved.quality)
		return Resolved(file: destination, rung: rung)
	}

	// MARK: - Offline resolve

	/// Runs the app's offline download path for one combination, into the temporary library,
	/// and reports the file it stored. The Download ceiling is the app's Download setting, set
	/// on the session for the run; the file is cleared between combinations so each ceiling is
	/// measured on its own download.
	private func offlineResolve(track: Track, combination: Combination) async -> Resolved? {
		let offline = session.helpers.offline
		clearOfflineLibrary()
		session.config.offlineAudioQuality = combination.ceiling.quality
		offline.setPreferDolbyAtmos(to: combination.atmos)
		await offline.add(track: track)

		guard let stream = await awaitOfflineFile(track: track, ceiling: combination.ceiling) else {
			return nil
		}
		let rung: HLSRung = stream.isDolbyAtmos ? .dolbyAtmos : .stereo(stream.quality ?? combination.ceiling.quality)
		return Resolved(file: stream.url, rung: rung)
	}

	/// Removes the files in the temporary offline library but keeps its folder, so the next
	/// combination downloads its own file rather than being served the previous one.
	private func clearOfflineLibrary() {
		let contents = (try? FileManager.default.contentsOfDirectory(
			at: offlineLibraryDirectory,
			includingPropertiesForKeys: nil
		)) ?? []
		for url in contents {
			try? FileManager.default.removeItem(at: url)
		}
	}

	private func awaitOfflineFile(track: Track, ceiling: Tier) async -> AudioStream? {
		let deadline = Date().addingTimeInterval(offlineTimeout)
		while Date() < deadline {
			if let stream = await session.helpers.offline.stream(for: track, ceiling: ceiling.quality) {
				return stream
			}
			try? await Task.sleep(for: .milliseconds(250))
		}
		return nil
	}

	/// A plain GET to a pre-signed URL, mirroring `Network.download`: a non-2xx answer is an
	/// error page, not the audio, so it is refused and the temporary file removed.
	private static func download(_ url: URL, to destination: URL) async throws {
		try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
		let (temporary, response) = try await URLSession.shared.download(from: url)
		if let statusCode = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(statusCode) {
			try? FileManager.default.removeItem(at: temporary)
			throw URLError(.badServerResponse)
		}
		if FileManager.default.fileExists(atPath: destination.path) {
			try FileManager.default.removeItem(at: destination)
		}
		try FileManager.default.moveItem(at: temporary, to: destination)
	}

	// MARK: - Output

	static let preamble = """
	verify-playback — rules versus reality.

	For each track and each combination of settings, three layers are printed side by side:

	  EXPECTED  the documented rules, written out by hand (see Expectations.swift)
	  DECIDED   what the library chose, read from the library itself
	  MEASURED  what was asked, what TIDAL answered, and what the bytes hold

	The verdict compares EXPECTED against MEASURED (and EXPECTED's rung order against the
	library's), so a mismatch is the point of the tool, not a failure. No AVPlayer is created:
	nothing plays and no sound is made. A fact marked (bytes) comes from the decoded stream;
	one marked (format) comes from the served rendition's manifest format, because a FLAC
	inside fMP4 reports a bit depth of 0 through AVFoundation while only the manifest carries
	the truth.
	"""

	private static func block(_ result: Result) -> String {
		var lines: [String] = []
		lines.append(String(repeating: "─", count: 78))
		let hiRes = result.hiRes ? ", hi-res" : ""
		lines.append("track \(result.trackId)  \(result.kind.rawValue)\(hiRes)")
		lines.append("combination: \(result.combination.path.rawValue), ceiling=\(result.combination.ceiling.rawValue), atmos=\(result.combination.atmos ? "on" : "off")")
		lines.append(row("EXPECTED", "rungs: \(result.expected.rungs.joined(separator: ", "))"))
		lines.append(row("", "atmos admitted at \(result.combination.ceiling.rawValue): \(result.expected.atmosAdmitted ? "yes" : "no")"))
		lines.append(row("", "served: \(result.expected.served)    badge: \(result.expected.badge)"))
		lines.append(row("DECIDED", "route: \(result.decided.route.joined(separator: ", "))"))
		lines.append(row("", "rungs: \(result.decided.rungs.joined(separator: ", "))"))
		lines.append(row("", "file: \(result.decided.file ?? "—")    badge rung: \(result.decided.badgeRung ?? "—")"))
		lines.append(row("MEASURED", "asked: \(result.measured.asked ?? "—")    answered: \(result.measured.answered ?? "—")"))
		lines.append(row("", decodedLine(result.measured.decoded, rung: result.rung)))
		lines.append(row("VERDICT", verdict(result)))
		return lines.joined(separator: "\n")
	}

	private static func row(_ label: String, _ text: String) -> String {
		"  " + label.padding(toLength: 9, withPad: " ", startingAt: 0) + text
	}

	private static func decodedLine(_ decoded: DecodedFacts?, rung: HLSRung?) -> String {
		guard let decoded else { return "no file decoded" }
		let codec = decoded.codec ?? "—"
		let depth = bitDepth(decoded: decoded, rung: rung)
		let rate = decoded.sampleRate.map { "\($0) Hz" } ?? "—"
		let channels = decoded.channels.map { "\($0)ch" } ?? "—"
		let bitrate = decoded.bitrateKbps.map { "\($0) kbps" } ?? "—"
		return "codec \(codec), depth \(depth), \(rate), \(channels), \(bitrate), \(size(decoded.sizeBytes))"
	}

	private static func bitDepth(decoded: DecodedFacts, rung: HLSRung?) -> String {
		if let bits = decoded.bitDepth { return "\(bits) (bytes)" }
		if let depth = manifestBitDepth(rung) { return "\(depth) (format)" }
		return "— (lossy)"
	}

	/// The verdict compares EXPECTED against the library's rung order and against MEASURED.
	private static func verdict(_ result: Result) -> String {
		var issues: [String] = []
		if result.expected.rungs != result.decided.rungs {
			issues.append("rungs: rules say [\(result.expected.rungs.joined(separator: ", "))], library ordered [\(result.decided.rungs.joined(separator: ", "))]")
		}
		if let rung = result.rung {
			let served = Expectations.rendition(of: rung)
			if served != result.expected.served {
				issues.append("served: rules say \(result.expected.served), measured \(served)")
			}
			let measuredBadge = HLSStreaming.badge(for: rung, sampleRate: result.measured.decoded?.sampleRate)
			if !(measuredBadge == result.expected.badge || measuredBadge.hasPrefix(result.expected.badge)) {
				issues.append("badge: rules say \(result.expected.badge), measured \(measuredBadge)")
			}
		} else {
			issues.append("nothing was served (rules say \(result.expected.served))")
		}
		return issues.isEmpty ? "match" : "MISMATCH — " + issues.joined(separator: "; ")
	}

	private static func summary(_ results: [Result]) -> String {
		let matches = results.filter { verdict($0) == "match" }.count
		let mismatches = results.filter { verdict($0).hasPrefix("MISMATCH") }.count
		let unresolved = results.count - matches - mismatches
		var lines = ["summary: \(results.count) combinations; \(matches) match, \(mismatches) mismatch, \(unresolved) no answer."]
		for result in results where verdict(result) != "match" {
			lines.append("  track \(result.trackId) [\(result.combination.path.rawValue) \(result.combination.ceiling.rawValue) atmos=\(result.combination.atmos ? "on" : "off")]: \(verdict(result))")
		}
		return lines.joined(separator: "\n")
	}

	/// The bit depth the served rung's manifest format promises. Only the FLAC formats name a
	/// depth; the lossy formats do not.
	static func manifestBitDepth(_ rung: HLSRung?) -> Int? {
		switch rung {
		case .stereo(.max):
			return 24
		case .stereo(.high):
			return 16
		default:
			return nil
		}
	}

	static func size(_ bytes: Int) -> String {
		guard bytes > 0 else { return "—" }
		if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
		return String(format: "%.1f KB", Double(bytes) / 1_000)
	}
}
