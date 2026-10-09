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
	/// The rung the library served, nil when it named no rendition (an unmarked legacy
	/// offline file carries no tier).
	let rung: HLSRung?
	/// The library's own badge for the served rung.
	let badge: String?
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
	/// The run was hermetic (`--fixture`), so the track's metadata is the fixture's own. Printed
	/// with the track so a pasted block identifies itself.
	let fixture: Bool
	let combination: Combination
	let expected: Expected
	let decided: Decided
	let measured: Measured
	/// Why no file was produced, when none was; nil when one was measured.
	let failure: ResolveFailure?
}

/// A resolved file and the rendition it holds.
struct Resolved {
	let file: URL
	let rung: HLSRung?
	/// The file came from the HLS manifest path (the stream or the offline sync), rather
	/// than the direct `streamUrl` ladder.
	let isHLS: Bool
}

/// Why a combination produced no file to measure.
enum ResolveFailure {
	/// The playback path served nothing at all.
	case nothingServed
	/// A stream resolved, but the file behind it could not be assembled or fetched.
	case assemblyFailed
}

/// What a resolve attempt produced: a file, or the reason it produced none.
enum ResolveOutcome {
	case resolved(Resolved)
	case nothingServed
	case assemblyFailed
}

struct Verifier {
	let options: Options
	let session: Session
	let assemblyDirectory: URL
	let directDirectory: URL
	let offlineLibraryDirectory: URL
	let offlineTimeout: TimeInterval = 120

	// MARK: - Entry

	/// The base name of the private defaults suite the offline redirect uses, under the run's
	/// temp root (`<root>/offline-defaults`, so the plist is `<root>/offline-defaults.plist`).
	static let scratchDefaultsSuite = "offline-defaults"

	static func run(options: Options) async -> Int {
		// A process without a bundle identifier caches HTTP traffic under
		// `~/Library/Caches/<process name>`, and CFNetwork keeps a per-process HTTP storage,
		// `httpstorages.sqlite` and its WAL, under `~/Library/HTTPStorages/<process name>`. An
		// empty URLCache stops the first coming back; it does not touch the second, which every
		// network run writes because the library's requests go through `URLSession.shared`. Both
		// directories are removed at the end of the run, and again at the start so a run made
		// before this cleanup is not left in the home directory.
		URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
		Self.removeToolLibraryDirectories()
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("verify-playback-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let offlineRoot = root.appendingPathComponent("offline")
		// The suite is named by an absolute path under the temp root so its plist is born in
		// temp; a plain suite name puts it under `~/Library/Preferences`, where cfprefsd
		// re-creates it after the process exits even once the domain is cleared. The instance
		// is created once and handed to the session so the cleanup clears the domain through
		// the object that wrote it.
		let scratchSuiteName = root.appendingPathComponent(Self.scratchDefaultsSuite).path
		let offlineDefaults = UserDefaults(suiteName: scratchSuiteName) ?? .standard
		offlineDefaults.removePersistentDomain(forName: scratchSuiteName)
		defer {
			// Clear the defaults domains first: the suite's plist lives under the temp root, and
			// flushing the domain after the root is gone re-creates an empty directory.
			Self.cleanUpScratchDefaults(offlineDefaults, suiteName: scratchSuiteName)
			Self.removeToolLibraryDirectories()
			try? FileManager.default.removeItem(at: root)
		}

		switch Self.sessionPlan(options: options) {
		case .notLoggedIn(let message):
			print(message)
			return 1
		case .ready(let config, let source):
			// The header prints before the session is built so the library's own startup log lands
			// below the tool's words instead of above them.
			print()
			print(Self.preamble)
			Self.printRunHeader(options)
			if let source { print("session: \(source)") }
			let session = Self.makeSession(config: config, offlineRoot: offlineRoot, offlineDefaults: offlineDefaults)
			StoredSession.apply(to: session, from: UserDefaults(suiteName: StoredSession.appDefaultsDomain))
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

	/// The line the report opens with: which path runs, and - for a fixture - that the track
	/// metadata below is the fixture's own, not a catalogue read, so a pasted run identifies
	/// itself. The last line names the library's log, whose `Offline:` lines would otherwise read
	/// as the tool's own.
	private static func printRunHeader(_ options: Options) {
		if let fixture = options.fixtureDirectory {
			print("fixture: \(fixture.path) — no account, no network; the track metadata below is built by the fixture, not read from the catalogue")
		} else if options.offline {
			print("offline: downloading through the app's sync into a temporary library; your real ~/Music/TidalSwift Offline Library is untouched")
		} else {
			print("stream: resolving into a temporary cache; your real playback cache and offline library are untouched")
		}
		print("log lines below prefixed Offline:, [PLAYBACK] and [NET] come from the library, not this tool")
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

	private enum SessionPlan {
		case ready(Config, SessionSource?)
		case notLoggedIn(String)
	}

	/// Resolves which configuration to run with, without building a `Session`: the fixture seam, a
	/// `TIDAL_TEST_TOKEN`, or the app's stored login, read the way the app stores it through the
	/// tool's own reader of the app's defaults domain (a command line tool's `UserDefaults.standard`
	/// is its own domain, not the app's). Building the session is left to the caller so the report
	/// header prints above the library's startup log. A `TIDAL_TEST_TOKEN` in the environment wins,
	/// for a run on a machine whose stored login has lapsed. A missing or expired stored session
	/// yields one clear line, never a guess or a crash. A fixture run needs no login: the fixture
	/// seam answers the manifest request, so no request is made.
	private static func sessionPlan(options: Options) -> SessionPlan {
		if options.fixtureDirectory != nil {
			return .ready(
				Config(accessToken: Fixture.desktopAccessToken, refreshToken: "", clientID: "", offlineAudioQuality: .max),
				nil
			)
		}
		if let token = ProcessInfo.processInfo.environment["TIDAL_TEST_TOKEN"], !token.isEmpty {
			guard SessionToken.looksLikeSessionToken(token) else {
				return .notLoggedIn("the session was refused: TIDAL_TEST_TOKEN does not hold a Tidal session token; log in through the TidalSwift app and run this again")
			}
			return .ready(Config(accessToken: token, refreshToken: "", clientID: "", offlineAudioQuality: .max), .environmentToken)
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
			return .ready(config, .stored)
		}
	}

	/// Builds the session with a temporary offline library, and redirects the offline
	/// preferences to a private suite, so the developer's real library and settings are never
	/// read or written. The redirect happens before any await, so the launch sync the offline
	/// manager starts cannot read the real domain first.
	private static func makeSession(config: Config, offlineRoot: URL, offlineDefaults: UserDefaults) -> Session {
		let session = Session(config: config, offlineLibraryRoot: offlineRoot)
		session.helpers.offline.defaults = offlineDefaults
		return session
	}

	/// The domain `UserDefaults.standard` maps to in this process: a command line tool has no
	/// bundle identifier, so Foundation uses the executable's name. It is the tool's own domain,
	/// never the app's, but a token refresh writes it through `saveConfig`.
	private static var standardDefaultsDomain: String {
		Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
	}

	/// True when the domain `UserDefaults.standard` maps to is the tool's own, never the app's.
	/// A tool launched with the app's bundle identifier would derive `io.hosh.TidalSwift` and every
	/// cleanup below would then delete the app's preferences, URL cache and HTTP storage. The
	/// preferences cleanup and the directory cleanup both route their guard through this one check
	/// so they cannot drift apart.
	private static var standardDomainIsOurs: Bool {
		standardDefaultsDomain != StoredSession.appDefaultsDomain
	}

	/// The tool writes its offline preferences to a path inside the temp root, so the offline
	/// domain is born under temp. The standard domain is cleared on every run, whether or not
	/// anything wrote it: right after `removePersistentDomain` the file still holds the old
	/// contents, and the unlink is what removes it. cfprefsd then recreates an empty
	/// `~/Library/Preferences/verify-playback.plist` after the process exits; it holds nothing and
	/// is transient, seen for about five seconds, once at fifty. The app's own domain is never
	/// touched: a stray bundle identifier must not turn this into a delete of the app's settings.
	private static func cleanUpScratchDefaults(_ offlineDefaults: UserDefaults, suiteName: String) {
		offlineDefaults.removePersistentDomain(forName: suiteName)
		offlineDefaults.synchronize()
		try? FileManager.default.removeItem(atPath: suiteName + ".plist")
		guard standardDomainIsOurs else { return }
		UserDefaults.standard.removePersistentDomain(forName: standardDefaultsDomain)
		UserDefaults.standard.synchronize()
		try? FileManager.default.removeItem(at: defaultsPlistURL(standardDefaultsDomain))
	}

	private static func defaultsPlistURL(_ domain: String) -> URL {
		URL(fileURLWithPath: NSHomeDirectory())
			.appendingPathComponent("Library/Preferences/\(domain).plist")
	}

	/// Removes the two directories a bundle-less process writes under the home directory, keyed by
	/// the derived domain: the URL cache at `~/Library/Caches/<domain>` and CFNetwork's per-process
	/// HTTP storage at `~/Library/HTTPStorages/<domain>`. Nothing is removed when the domain is the
	/// app's own (see `standardDomainIsOurs`).
	private static func removeToolLibraryDirectories() {
		guard standardDomainIsOurs else { return }
		let home = URL(fileURLWithPath: NSHomeDirectory())
		for subdirectory in ["Caches", "HTTPStorages"] {
			let url = home.appendingPathComponent("Library/\(subdirectory)/\(standardDefaultsDomain)", isDirectory: true)
			try? FileManager.default.removeItem(at: url)
		}
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
				print("track \(trackId): could not be read from the catalogue; if your login has lapsed, log in through the TidalSwift app and run this again; skipping")
				everyTrackReadable = false
				continue
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

		let resolveOutcome: ResolveOutcome
		switch combination.path {
		case .stream:
			resolveOutcome = await streamResolve(track: track, combination: combination)
		case .offline:
			resolveOutcome = await offlineResolve(track: track, combination: combination)
		}

		let resolved: Resolved?
		let failure: ResolveFailure?
		switch resolveOutcome {
		case .resolved(let value):
			resolved = value
			failure = nil
		case .nothingServed:
			resolved = nil
			failure = .nothingServed
		case .assemblyFailed:
			resolved = nil
			failure = .assemblyFailed
		}

		let decoded: DecodedFacts?
		if let resolved {
			decoded = await AudioDecoder.decode(resolved.file)
		} else {
			decoded = nil
		}

		let decided = Self.decided(track: track, combination: combination, session: session, resolved: resolved)
		let measured = Self.measured(track: track, combination: combination, resolved: resolved, decoded: decoded, route: decided.route)
		return Result(
			trackId: track.id,
			kind: kind,
			hiRes: hiRes,
			fixture: options.fixtureDirectory != nil,
			combination: combination,
			expected: expected,
			decided: decided,
			measured: measured,
			failure: failure
		)
	}

	/// DECIDED — the library's own choices, read from its public surface: the route list, the
	/// rung order, the file it chose, and the rung and badge for the rendition it served.
	private static func decided(track: Track, combination: Combination, session: Session, resolved: Resolved?) -> Decided {
		let route = PlaybackRoutingPolicy
			.routes(sessionHasDesktopPlaybackAccess: session.hasDesktopPlaybackAccess)
			.map { $0 == .hls ? "hls" : "directStream" }
		let rungs = HLSStreaming.rungs(
			for: combination.ceiling.quality,
			preferDolbyAtmos: combination.atmos,
			trackHasDolbyAtmos: track.hasDolbyAtmos
		).map(\.format)
		var servedRung: HLSRung?
		if let resolved { servedRung = resolved.rung }
		return Decided(
			route: route,
			rungs: rungs,
			file: resolved?.file.lastPathComponent,
			rung: servedRung,
			badge: servedRung.map { HLSStreaming.badge(for: $0) }
		)
	}

	/// MEASURED — what the tool asked the endpoint for, what TIDAL answered, and the decoded
	/// facts. No `AVPlayer` is created, so nothing plays.
	private static func measured(track: Track, combination: Combination, resolved: Resolved?, decoded: DecodedFacts?, route: [String]) -> Measured {
		Measured(
			asked: asked(track: track, combination: combination, resolved: resolved, route: route),
			answered: resolved?.rung?.format,
			decoded: decoded
		)
	}

	/// The request the measured route makes. The HLS and offline paths ask the rungs' first
	/// format; the direct ladder asks the Atmos rendition when the preference is on, then walks
	/// the quality ladder down from the ceiling. A failure row still names the route the walk
	/// starts with, so a blank is never printed where a request happened.
	private static func asked(track: Track, combination: Combination, resolved: Resolved?, route: [String]) -> String? {
		let isHLS: Bool
		if let resolved {
			isHLS = resolved.isHLS
		} else if combination.path == .offline {
			isHLS = true
		} else {
			isHLS = route.first == "hls"
		}
		return isHLS ? hlsAsked(track: track, combination: combination) : directAsked(track: track, combination: combination)
	}

	private static func hlsAsked(track: Track, combination: Combination) -> String? {
		HLSStreaming.rungs(
			for: combination.ceiling.quality,
			preferDolbyAtmos: combination.atmos,
			trackHasDolbyAtmos: track.hasDolbyAtmos
		).first?.format
	}

	private static func directAsked(track: Track, combination: Combination) -> String {
		var asks: [String] = []
		if track.hasDolbyAtmos, combination.ceiling.quality.admitsDolbyAtmos, combination.atmos {
			asks.append("Dolby Atmos")
		}
		asks.append("\(combination.ceiling.quality.rawValue) and below")
		return asks.joined(separator: ", then ")
	}

	// MARK: - Streaming resolve

	/// The production resolve for one combination. It calls the player's own entry,
	/// `session.playableStream`, which walks the route policy exactly as a play does, then
	/// measures the file behind the stream: the HLS cache write it started, the cached file it
	/// returned, or a fetch of the direct ladder's pre-signed URL. A non-nil `resolvePlaylist`
	/// is the fixture seam, which makes no request. Nothing here reimplements the walk.
	private func streamResolve(track: Track, combination: Combination) async -> ResolveOutcome {
		let resolvePlaylist: ((Int, HLSRung) async throws -> URL)? = options.fixtureDirectory.map { fixture in
			Fixture.resolver(multivariantURL: fixture.appendingPathComponent("master.m3u8"))
		}
		// One cache directory per track, ceiling and preference: the cache serves any rung on a
		// ceiling's ladder, so a shared directory would let one combination's cached file answer
		// the next combination's request and hide what that combination actually serves.
		let cacheDirectory = assemblyDirectory.appendingPathComponent(
			"\(track.id)-\(combination.ceiling.rawValue)-\(combination.atmos ? "atmos" : "stereo")", isDirectory: true
		)
		guard let stream = await session.playableStream(
			for: track,
			quality: combination.ceiling.quality,
			preferDolbyAtmos: combination.atmos,
			cacheDirectory: cacheDirectory,
			resolvePlaylist: resolvePlaylist
		) else { return .nothingServed }

		let rung: HLSRung? = stream.isDolbyAtmos ? .dolbyAtmos : .stereo(stream.quality)
		if stream.isHLS {
			// The cache write a play starts behind the playlist, or the cached file itself.
			if let download = stream.backgroundDownload {
				guard let file = await download.value else { return .assemblyFailed }
				return .resolved(Resolved(file: file, rung: rung, isHLS: true))
			}
			return .resolved(Resolved(file: stream.url, rung: rung, isHLS: true))
		}
		// The direct route hands back a pre-signed URL; fetch it the way the offline sync does.
		let extensionPart = stream.url.pathExtension.isEmpty ? "bin" : stream.url.pathExtension
		let destination = directDirectory.appendingPathComponent("\(track.id)-\(combination.ceiling.rawValue).\(extensionPart)")
		do {
			try await Self.download(stream.url, to: destination)
		} catch {
			return .assemblyFailed
		}
		return .resolved(Resolved(file: destination, rung: rung, isHLS: false))
	}

	// MARK: - Offline resolve

	/// Runs the app's offline download path for one combination, into the temporary library,
	/// and reports the file it stored. The Download ceiling is the app's Download setting, set
	/// on the session for the run; the file is cleared between combinations so each ceiling is
	/// measured on its own download.
	private func offlineResolve(track: Track, combination: Combination) async -> ResolveOutcome {
		let offline = session.helpers.offline
		clearOfflineLibrary()
		session.config.offlineAudioQuality = combination.ceiling.quality
		offline.setPreferDolbyAtmos(to: combination.atmos)
		await offline.add(track: track)

		// The sync can restart itself (`Something changed`), and its writes land in the private
		// defaults suite; wait for the whole chain to settle so the file measured is this
		// combination's and no write lands after the run cleans up.
		await offline.awaitOngoingSync(timeout: offlineTimeout)
		guard let stream = await awaitOfflineFile(track: track, ceiling: combination.ceiling) else {
			return .nothingServed
		}
		// The sync names the tier only when the stored file carries one; an unmarked legacy file
		// reports none, and the app's own play leaves the rung unset the same way rather than
		// inventing the ceiling's tier.
		let rung: HLSRung? = stream.isDolbyAtmos ? .dolbyAtmos : stream.quality.map(HLSRung.stereo)
		return .resolved(Resolved(file: stream.url, rung: rung, isHLS: true))
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

	The verdict compares EXPECTED against MEASURED: the library's rung order and badge, the
	codec family, the channel count, and the bit depth the FLAC bytes record. A mismatch is the
	point of the tool, not a failure, and a combination where nothing was served counts as
	"no answer" rather than a rules error. No AVPlayer is created: nothing plays and no sound
	is made. Where the bytes cannot settle a fact the verdict reads UNVERIFIED and the summary
	counts it separately, never as agreement: an fMP4 FLAC reports no depth through AVFoundation
	so the depth is read from the file's own FLAC STREAMINFO, the two lossy tiers share one
	codec, and `ec-3` is the same whether or not the Atmos object layer travels with it. A depth
	read from the bytes is marked (bytes).
	"""

	private static func block(_ result: Result) -> String {
		var lines: [String] = []
		lines.append(String(repeating: "─", count: 78))
		let hiRes = result.hiRes ? ", hi-res" : ""
		let fixture = result.fixture ? "  (fixture)" : ""
		lines.append("track \(result.trackId)  \(result.kind.rawValue)\(hiRes)\(fixture)")
		lines.append("combination: \(result.combination.path.rawValue), ceiling=\(result.combination.ceiling.rawValue), atmos=\(result.combination.atmos ? "on" : "off")")
		lines.append(row("EXPECTED", "rungs: \(result.expected.rungs.joined(separator: ", "))"))
		lines.append(row("", "atmos admitted at \(result.combination.ceiling.rawValue): \(result.expected.atmosAdmitted ? "yes" : "no")"))
		lines.append(row("", "served: \(result.expected.served)    badge: \(result.expected.badge)"))
		lines.append(row("DECIDED", "route: \(result.decided.route.joined(separator: ", "))"))
		lines.append(row("", "rungs: \(result.decided.rungs.joined(separator: ", "))"))
		lines.append(row("", "file: \(result.decided.file ?? "—")    rung: \(result.decided.rung?.format ?? "—")    badge: \(result.decided.badge ?? "—")"))
		lines.append(row("MEASURED", "asked: \(result.measured.asked ?? "—")    answered: \(result.measured.answered ?? "—")"))
		lines.append(row("", decodedLine(result.measured.decoded)))
		lines.append(row("VERDICT", verdict(result)))
		return lines.joined(separator: "\n")
	}

	private static func row(_ label: String, _ text: String) -> String {
		"  " + label.padding(toLength: 9, withPad: " ", startingAt: 0) + text
	}

	private static func decodedLine(_ decoded: DecodedFacts?) -> String {
		guard let decoded else { return "no file decoded" }
		let codec = decoded.codec ?? "—"
		let depth = bitDepth(decoded: decoded)
		let rate = decoded.sampleRate.map { "\($0) Hz" } ?? "—"
		let channels = decoded.channels.map { "\($0)ch" } ?? "—"
		let bitrate = decoded.bitrateKbps.map { "\($0) kbps" } ?? "—"
		return "codec \(codec), depth \(depth), \(rate), \(channels), \(bitrate), \(size(decoded.sizeBytes))"
	}

	/// The depth as the bytes report it. A FLAC native stream reports it through AVFoundation; an
	/// fMP4 FLAC does not, and the depth is read from its STREAMINFO instead. A file that names
	/// no depth prints a dash rather than borrowing the manifest's label.
	private static func bitDepth(decoded: DecodedFacts) -> String {
		if let bits = decoded.bitDepth { return "\(bits) (bytes)" }
		return "—"
	}

	private enum Outcome: Equatable {
		case match
		case mismatch
		case noAnswer
		case unverified
	}

	/// The verdict compares EXPECTED against MEASURED: the library's rung order and badge, and
	/// the codec family, channel count and bit depth the decoded bytes actually hold.
	private static func verdict(_ result: Result) -> String {
		let (outcome, text) = judge(result)
		switch outcome {
		case .match:
			return text
		case .mismatch:
			return "MISMATCH — " + text
		case .noAnswer:
			return "no answer — " + text
		case .unverified:
			return "UNVERIFIED — " + text
		}
	}

	/// The outcome for one combination and the text that explains it. Issues mean a mismatch.
	/// A note means the bytes could not settle a fact: that is unverified, counted on its own,
	/// never folded into the match count.
	private static func judge(_ result: Result) -> (Outcome, String) {
		guard result.decided.file != nil else {
			switch result.failure {
			case .assemblyFailed:
				return (.noAnswer, "nothing was measured: a stream resolved but its file could not be assembled")
			default:
				return (.noAnswer, "nothing was served (rules say \(result.expected.served))")
			}
		}
		var issues: [String] = []
		if result.expected.rungs != result.decided.rungs {
			issues.append("rungs: rules say [\(result.expected.rungs.joined(separator: ", "))], library ordered [\(result.decided.rungs.joined(separator: ", "))]")
		}
		if let rung = result.decided.rung {
			let measuredBadge = HLSStreaming.badge(for: rung, sampleRate: result.measured.decoded?.sampleRate)
			if !(measuredBadge == result.expected.badge || measuredBadge.hasPrefix(result.expected.badge)) {
				issues.append("badge: rules say \(result.expected.badge), measured \(measuredBadge)")
			}
		}
		var notes: [String] = []
		byteFindings(result, issues: &issues, notes: &notes)
		guard issues.isEmpty else { return (.mismatch, issues.joined(separator: "; ")) }
		guard notes.isEmpty else { return (.unverified, notes.joined(separator: "; ")) }
		return (.match, "match")
	}

	/// What the decoded bytes settle: the codec family, the channel count, and the FLAC bit
	/// depth. A fact the bytes cannot settle is a note, and a note makes the row unverified, not
	/// a match. A missing codec stops the check: with no codec to read, nothing was verified.
	private static func byteFindings(_ result: Result, issues: inout [String], notes: inout [String]) {
		let rendition = result.expected.served
		guard let decoded = result.measured.decoded, let codec = decoded.codec else {
			notes.append("codec unverified: the decoded file names no codec")
			return
		}
		if let family = Expectations.codecFamily(ofRendition: rendition), !Expectations.codecMatches(codec, family: family) {
			issues.append("codec: rules expect \(family), bytes are \(codec)")
		}
		if rendition == "atmos" {
			if decoded.channels.map({ $0 < 2 }) ?? false {
				issues.append("channels: an Atmos rendition cannot be \(decoded.channels ?? 0)ch")
			} else if decoded.channels == nil {
				notes.append("channels unverified: the decoded file reports no channel count")
			} else if !issues.contains(where: { $0.hasPrefix("codec:") }) {
				// ec-3 is the codec Atmos travels in, but a plain E-AC-3 stream carries it too; the
				// JOC object layer is not part of the format description, so the bytes cannot confirm
				// Atmos itself.
				notes.append("atmos unverified: the bytes name ec-3, which is not by itself the Atmos object layer")
			}
		} else if let expectedChannels = Expectations.channels(ofRendition: rendition) {
			if let channels = decoded.channels {
				if channels != expectedChannels {
					issues.append("channels: rules expect \(expectedChannels)ch, bytes are \(channels)ch")
				}
			} else {
				notes.append("channels unverified: the decoded file reports no channel count")
			}
		}
		guard let expectedDepth = Expectations.bitDepth(ofRendition: rendition) else { return }
		if let bits = decoded.bitDepth {
			if bits != expectedDepth {
				issues.append("depth: rules say \(expectedDepth)-bit, bytes say \(bits)-bit")
			}
		} else {
			notes.append("depth unverified: the file's bytes name no bit depth")
		}
	}

	private static func summary(_ results: [Result]) -> String {
		let outcomes = results.map { judge($0).0 }
		let matches = outcomes.filter { $0 == .match }.count
		let mismatches = outcomes.filter { $0 == .mismatch }.count
		let unresolved = outcomes.filter { $0 == .noAnswer }.count
		let unverified = outcomes.filter { $0 == .unverified }.count
		let combinations = results.count == 1 ? "1 combination" : "\(results.count) combinations"
		var lines = ["summary: \(combinations); \(matches) match, \(mismatches) mismatch, \(unresolved) no answer, \(unverified) unverified."]
		for result in results where judge(result).0 != .match {
			lines.append("  track \(result.trackId) [\(result.combination.path.rawValue) \(result.combination.ceiling.rawValue) atmos=\(result.combination.atmos ? "on" : "off")]: \(verdict(result))")
		}
		return lines.joined(separator: "\n")
	}

	static func size(_ bytes: Int) -> String {
		guard bytes > 0 else { return "—" }
		if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
		return String(format: "%.1f KB", Double(bytes) / 1_000)
	}
}
