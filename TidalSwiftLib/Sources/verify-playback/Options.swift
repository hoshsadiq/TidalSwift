//
//  Options.swift
//  verify-playback
//
//  Command-line options for the playback verifier.
//

import Foundation
import TidalSwiftLib

/// A quality setting as the app's picker names it. `low320` is the 320 kbps setting the
/// library stores as `.medium`; the report prints a served stereo tier back through this
/// mapping so a row reads the same as the setting it came from.
enum Tier: String, CaseIterable, Sendable {
	case low
	case low320
	case lossless
	case max

	var quality: AudioQuality {
		switch self {
		case .low:
			return .low
		case .low320:
			return .medium
		case .lossless:
			return .high
		case .max:
			return .max
		}
	}

	static func of(_ quality: AudioQuality) -> Tier {
		switch quality {
		case .low:
			return .low
		case .medium:
			return .low320
		case .high:
			return .lossless
		case .max:
			return .max
		}
	}
}

/// A parse failure; the caller prints it and the usage text.
struct OptionsError: Error, CustomStringConvertible {
	let description: String
}

/// What the tool was asked to run. The two ceilings are separate settings on purpose: a
/// streaming run uses the Stream ceiling, an offline run the Download ceiling, and the point
/// of the report is that they are different knobs.
struct Options {
	var trackIds: [Int]
	/// The Stream ceiling(s) to run. `--stream-ceiling` is an alias; `--matrix` widens the
	/// empty default to every tier.
	var streamCeilings: [Tier]
	/// The Download ceiling(s) to run with `--offline`. Empty means the stored setting.
	var downloadCeilings: [Tier]
	var atmos: Bool
	var atmosGiven: Bool
	var offline: Bool
	var matrix: Bool
	var fixtureDirectory: URL?

	/// A hi-res stereo track, a plain stereo track, and one TIDAL advertises as Atmos with no
	/// stereo — so a bare run shows each rule the expectation table turns on.
	static let defaultTrackIds = [98_156_344, 1_228_498, 241_647_167]

	static func parse(_ arguments: [String]) throws -> Options {
		var parser = Parser(arguments: arguments)
		try parser.scan()
		return try parser.options()
	}

	/// Scans the arguments into the raw flags, then applies the defaults. Split out so no one
	/// function carries both the loop and the defaulting.
	private struct Parser {
		let arguments: [String]
		var index = 0
		var trackIds: [Int] = []
		var streamCeilings: [Tier] = []
		var downloadCeilings: [Tier] = []
		var atmos = false
		var atmosGiven = false
		var offline = false
		var matrix = false
		var fixtureDirectory: URL?
		var sawTrack = false

		mutating func scan() throws {
			while index < arguments.count {
				try step()
			}
		}

		private mutating func step() throws {
			let argument = arguments[index]
			switch argument {
			case "--track":
				let raw = try nextValue(for: "--track")
				guard let id = Int(raw) else {
					throw OptionsError(description: "--track needs a numeric track id, got \(raw)")
				}
				trackIds.append(id)
				sawTrack = true
			case "--tier", "--stream-ceiling":
				streamCeilings.append(try tier(argument))
			case "--download-ceiling":
				downloadCeilings.append(try tier("--download-ceiling"))
			case "--atmos":
				atmos = try boolValue(for: "--atmos")
				atmosGiven = true
			case "--offline":
				offline = true
			case "--matrix":
				matrix = true
			case "--fixture":
				fixtureDirectory = Options.resolvePath(try nextValue(for: "--fixture"))
			default:
				throw OptionsError(description: "unknown option \(argument)")
			}
			index += 1
		}

		private mutating func nextValue(for flag: String) throws -> String {
			guard index + 1 < arguments.count else {
				throw OptionsError(description: "\(flag) needs a value")
			}
			index += 1
			return arguments[index]
		}

		private mutating func tier(_ flag: String) throws -> Tier {
			let raw = try nextValue(for: flag)
			guard let tier = Tier(rawValue: raw) else {
				throw OptionsError(description: "\(flag) must be one of \(Tier.allCases.map(\.rawValue).joined(separator: ", ")), got \(raw)")
			}
			return tier
		}

		private mutating func boolValue(for flag: String) throws -> Bool {
			switch try nextValue(for: flag) {
			case "on", "true":
				return true
			case "off", "false":
				return false
			default:
				throw OptionsError(description: "\(flag) must be on or off, got \(arguments[index])")
			}
		}

		func options() throws -> Options {
			if offline, fixtureDirectory != nil {
				throw OptionsError(description: "--fixture runs the streaming HLS path and cannot be combined with --offline")
			}
			if offline, !streamCeilings.isEmpty {
				throw OptionsError(description: "--tier/--stream-ceiling is the Stream ceiling; an offline run uses --download-ceiling")
			}
			if !offline, !downloadCeilings.isEmpty {
				throw OptionsError(description: "--download-ceiling only applies to --offline; a streaming run uses --tier or --stream-ceiling")
			}
			if let fixtureDirectory {
				try validateFixtureDirectory(fixtureDirectory)
			}
			return Options(
				trackIds: sawTrack ? trackIds : Options.defaultTrackIds,
				streamCeilings: streamCeilings,
				downloadCeilings: downloadCeilings,
				atmos: atmos,
				atmosGiven: atmosGiven,
				offline: offline,
				matrix: matrix,
				fixtureDirectory: fixtureDirectory
			)
		}

		/// A fixture is only usable when the directory and its `master.m3u8` are there; without
		/// this an unreadable path printed eight rules mismatches and exited 0.
		private func validateFixtureDirectory(_ directory: URL) throws {
			var isDirectory: ObjCBool = false
			guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
				throw OptionsError(description: "--fixture needs a directory holding master.m3u8; \(directory.path) is not a directory")
			}
			guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("master.m3u8").path) else {
				throw OptionsError(description: "--fixture: \(directory.path) holds no master.m3u8")
			}
		}
	}

	/// Resolves a path the way the shell the user typed it in would: a relative path is
	/// relative to where the command ran, not to the directory this tool launches from (the
	/// mise task runs it from `TidalSwiftLib/`). The task passes the invocation directory in
	/// `VERIFY_PLAYBACK_PWD`.
	static func resolvePath(_ raw: String) -> URL {
		if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
		let base = ProcessInfo.processInfo.environment["VERIFY_PLAYBACK_PWD"] ?? FileManager.default.currentDirectoryPath
		return URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardizedFileURL
	}

	static let usage = """
	usage: mise run verify-playback [options]

	For each track and each combination of settings, print three layers side by side:
	EXPECTED (the rules, written out by hand from the docs), DECIDED (what the library chose),
	and MEASURED (what TIDAL answered and what the bytes really hold), then a verdict that
	compares EXPECTED against MEASURED. Nothing is asserted; a mismatch is the output, not a
	failure. No audio is played.

	Options:
	  --track <id>            Track id to verify. Repeatable. Defaults to a small known set
	                          covering a hi-res stereo track, a plain stereo track, and one
	                          TIDAL advertises as Atmos with no stereo.
	  --tier <tier>           Stream ceiling to run: low | low320 | lossless | max. Repeatable.
	                          Default: all four. Same as --stream-ceiling.
	  --stream-ceiling <tier> The Stream quality setting to run. Repeatable; alias of --tier.
	  --download-ceiling <t>  The Download quality setting to run with --offline. Repeatable.
	                          Only for --offline; a streaming run rejects it.
	                          Default: your stored Download quality (every tier with --matrix).
	  --atmos on|off          The Atmos preference. Default: off. Use --matrix to sweep both.
	  --offline               Measure the app's offline download path (into a temporary library;
	                          your real ~/Music/TidalSwift Offline Library is untouched). Uses
	                          the Download ceiling, not the Stream ceiling.
	  --matrix                Sweep an unset ceiling over every tier and an unset Atmos
	                          preference over both; a ceiling or preference you name is not
	                          widened. Downloads a track per measured combination, so it is
	                          slow; narrow it with --track.
	  --fixture <dir>         Run the streaming HLS path against a local fixture directory
	                          holding master.m3u8 and its segments, with no network or login.
	                          Not combinable with --offline. The path is relative to the
	                          directory you ran the command in. Recipe under Fixture below.
	  -h, --help              Print this help.

	The session is read from the app's stored login (its UserDefaults domain). If it is missing
	or expired the tool prints one clear line and exits non-zero, so log in through the app
	first. A TIDAL_TEST_TOKEN environment variable, when set, is used instead. No token, signed
	URL or account id is ever printed; at most a host.

	Fixture:
	  The no-account path. A fixture directory holds master.m3u8 and the segments it names; the
	  resolver answers every rung with it, so nothing touches the network. Build one with
	  ffmpeg, in the directory you will pass:

	    ffmpeg -f lavfi -i "sine=frequency=440:duration=3" -c:a flac -f hls \\
	      -hls_playlist_type vod -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 \\
	      -hls_segment_filename "seg%d.m4s" index.m3u8
	    printf '#EXTM3U\\n#EXT-X-VERSION:7\\n#EXT-X-STREAM-INF:BANDWIDTH=890000,CODECS="flac"\\nindex.m3u8\\n' > master.m3u8

	  That fixture holds one mono FLAC rendition. A hermetic run therefore matches where it
	  expects FLAC and mismatches where it expects AAC or Atmos, because the bytes cannot hold
	  those codecs: the verdict reads the codec family out of the decoded file, not the request.
	"""
}
