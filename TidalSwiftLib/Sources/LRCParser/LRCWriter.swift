//
//  LRCWriter.swift
//  LRCParser
//

import Foundation

/// Renders timed lyric lines back into an LRC document.
///
/// The counterpart of `LRCParser.parse`, so a result can be stored as text and read again:
/// an offline file carries its lyrics as LRC, and a player that understands the format can
/// use the timings rather than a wall of words.
public enum LRCWriter {
	/// Renders `lines` as `[mm:ss.xx]text`, the shape most LRC writers produce. A negative
	/// time is clamped to zero, since a timestamp cannot run backwards.
	public static func encode(_ lines: [LyricLine]) -> String {
		lines.map { line in
			// Round to the hundredth before splitting, so 59.996 becomes one minute rather than
			// `[00:60.00]`, which no LRC reader accepts.
			let hundredths = Int((max(0, line.time) * 100).rounded())
			let minutes = hundredths / 6000
			let seconds = Double(hundredths % 6000) / 100
			return String(format: "[%02d:%05.2f]%@", minutes, seconds, line.text)
		}
		.joined(separator: "\n")
	}
}
