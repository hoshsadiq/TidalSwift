//
//  Expectations.swift
//  verify-playback
//
//  EXPECTED — the documented rules, written out by hand as literals.
//

import Foundation
import TidalSwiftLib

/// Which renditions a track advertises. The Atmos rung is only asked for a track that
/// advertises Atmos; with the preference off it is the fallback, reached only when Tidal
/// serves no stereo. See `servedRendition`.
enum TrackKind: String {
	case stereoOnly = "stereo-only"
	case both = "stereo+atmos"
	case atmosOnly = "atmos-only"

	static func of(_ track: Track) -> TrackKind {
		switch (track.hasStereo, track.hasDolbyAtmos) {
		case (true, true):
			return .both
		case (false, true):
			return .atmosOnly
		default:
			return .stereoOnly
		}
	}

	var advertisesAtmos: Bool { self != .stereoOnly }
}

/// EXPECTED — the rules, written out by hand.
///
/// Every value below is a literal a person copied from the documented rules (AGENTS.md, the
/// comments in `HLSStreaming`/`AudioQuality`, and `docs/`). **Nothing here calls
/// `HLSStreaming.rungs`, `AudioQuality.admitsDolbyAtmos`, `HLSStreaming.badge` or any other
/// function that produces the behaviour.** That is deliberate and it is the whole point: if the
/// expectation were computed by the same code, EXPECTED and DECIDED would be the same expression
/// and the verdict could never read "mismatch" — a comparison that tests nothing. Written down
/// independently, a rule change the docs and this table miss shows up as a real mismatch.
enum Expectations {
	/// The stereo rung formats asked at a ceiling, highest first. The ceiling is a ceiling, not
	/// an exact tier: the play walks down from it (`AudioQualityPolicy.ladder` is
	/// low, medium, high, max, walked downward). Literal format names as the manifest endpoint
	/// spells them.
	static func stereoRungFormats(at ceiling: Tier) -> [String] {
		switch ceiling {
		case .max:
			return ["FLAC_HIRES", "FLAC", "AACLC", "HEAACV1"]
		case .lossless:
			return ["FLAC", "AACLC", "HEAACV1"]
		case .low320:
			return ["AACLC", "HEAACV1"]
		case .low:
			return ["HEAACV1"]
		}
	}

	/// Atmos is asked only at a High or Max ceiling: it is a ~768 kbps E-AC-3 stream with no
	/// lower variant (`AudioQuality.admitsDolbyAtmos`).
	static func atmosAdmitted(at ceiling: Tier) -> Bool {
		ceiling == .lossless || ceiling == .max
	}

	/// The rungs asked, in order. The Atmos rung is prepended when the preference is on and
	/// appended as a fallback when it is off; it is only asked for a track that advertises
	/// Atmos and only at a ceiling that admits it.
	static func rungs(at ceiling: Tier, atmos: Bool, kind: TrackKind) -> [String] {
		let stereo = stereoRungFormats(at: ceiling)
		guard kind.advertisesAtmos, atmosAdmitted(at: ceiling) else { return stereo }
		return atmos ? ["EAC3_JOC"] + stereo : stereo + ["EAC3_JOC"]
	}

	/// The rendition expected to be served, from the rules and the track kind.
	///
	/// - Atmos wins when it is admitted and the preference asks for it.
	/// - Otherwise the top stereo rung is served — also for a track the catalogue advertises as
	///   Atmos with no stereo. `audioModes` is not a stereo test: Tidal's manifest serves a
	///   stereo FLAC for track 241647167, whose catalogue entry is `audioModes: [DOLBY_ATMOS]`
	///   and no `STEREO` (measured 2026-10-08, recorded in `docs/tidal-streaming-api.md`, and
	///   reproduced live by this tool on 2026-10-09). The Atmos rung is the fallback for a track
	///   Tidal serves no stereo for, not the expected answer for an Atmos-advertised one.
	/// - `FLAC_HIRES` is documented to be refused for every track but a hi-res one, so a Max
	///   request on an ordinary track is expected to step down to the lossless FLAC rung.
	static func servedRendition(at ceiling: Tier, atmos: Bool, kind: TrackKind, hiRes: Bool) -> String {
		if kind.advertisesAtmos, atmosAdmitted(at: ceiling), atmos {
			return "atmos"
		}
		let stereo = stereoRungFormats(at: ceiling)
		if stereo.first == "FLAC_HIRES", !hiRes { return "lossless" }
		return renditionName(ofRungFormat: stereo.first ?? "")
	}

	/// The badge a served rendition should read. Literal strings from `HLSStreaming.badge`'s
	/// documented mapping, without the sample-rate suffix a measured run appends.
	static func badge(forRendition rendition: String) -> String {
		switch rendition {
		case "atmos":
			return "Dolby Atmos"
		case "max":
			return "24-bit"
		case "lossless":
			return "16-bit"
		case "low320":
			return "320 kbps"
		case "low":
			return "96 kbps"
		default:
			return "—"
		}
	}

	/// The codec family the expected rendition's bytes must hold. Literal four-character names
	/// as AVFoundation reports them: the FLAC formats are `flac`, both AAC tiers are `aac`
	/// (HE-AAC is AAC with SBR, so the two lossy tiers cannot be told apart by codec), and
	/// Atmos is `ec-3`, the codec Dolby Atmos travels in. `ec-3` is necessary for Atmos but not
	/// sufficient: the object-audio layer (JOC) is not part of the format description, so a
	/// plain E-AC-3 stream and an Atmos one share it, which the verdict reports as a note.
	static func codecFamily(ofRendition rendition: String) -> String? {
		switch rendition {
		case "atmos":
			return "ec-3"
		case "max", "lossless":
			return "flac"
		case "low320":
			return "aac"
		case "low":
			return "heaac"
		default:
			return nil
		}
	}

	/// Whether a decoded codec belongs to an expected family. The bytes name both AAC tiers
	/// `aac`, so the 96 tier's `heaac` family accepts it too; the decoded codec genuinely cannot
	/// tell the 320 tier from the 96 one, and the printed bitrate is what a reader judges that
	/// by (see the family note in the docs).
	static func codecMatches(_ codec: String, family: String) -> Bool {
		switch family {
		case "aac", "heaac":
			return codec == "aac" || codec == "aacp"
		default:
			return codec == family
		}
	}

	/// The channel count the expected rendition's bytes must hold, or nil where the count is a
	/// minimum rather than an equality. Every stereo rendition is two channels, so a mono file
	/// served for one is a wrong rendition; Atmos is multichannel, and the verdict checks its
	/// minimum separately.
	static func channels(ofRendition rendition: String) -> Int? {
		switch rendition {
		case "max", "lossless", "low320", "low":
			return 2
		default:
			return nil
		}
	}

	/// The bit depth the expected rendition promises, or nil where the format names none. Read
	/// from the FLAC STREAMINFO inside the file, not the manifest: a Max rung answered with a
	/// 16-bit FLAC must read as a mismatch, which is the point of this check.
	static func bitDepth(ofRendition rendition: String) -> Int? {
		switch rendition {
		case "max":
			return 24
		case "lossless":
			return 16
		default:
			return nil
		}
	}

	/// The setting name a rung format maps to, for comparing EXPECTED with the served rung.
	static func renditionName(ofRungFormat format: String) -> String {
		switch format {
		case "FLAC_HIRES":
			return "max"
		case "FLAC":
			return "lossless"
		case "AACLC":
			return "low320"
		case "HEAACV1":
			return "low"
		case "EAC3_JOC":
			return "atmos"
		default:
			return format
		}
	}
}
