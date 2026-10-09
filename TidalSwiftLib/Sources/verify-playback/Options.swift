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
				fixtureDirectory = URL(fileURLWithPath: try nextValue(for: "--fixture"))
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
	                          Default: your stored Download quality (every tier with --matrix).
	  --atmos on|off          The Atmos preference. Default: off. Use --matrix to sweep both.
	  --offline               Measure the app's offline download path (into a temporary library;
	                          your real ~/Music/TidalSwift Offline Library is untouched). Uses
	                          the Download ceiling, not the Stream ceiling.
	  --matrix                Sweep every combination of ceiling and Atmos preference instead
	                          of the one you name. Downloads a track per measured combination,
	                          so it is slow; narrow it with --track.
	  --fixture <dir>         Run the streaming HLS path against a local fixture directory
	                          holding master.m3u8 and its segments, with no network or login.
	                          Not combinable with --offline.
	  -h, --help              Print this help.

	The session is read from the app's stored login (its UserDefaults domain). If it is missing
	or expired the tool prints one clear line and exits non-zero, so log in through the app
	first. A TIDAL_TEST_TOKEN environment variable, when set, is used instead. No token, signed
	URL or account id is ever printed; at most a host.
	"""
}
