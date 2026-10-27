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
			let total = max(0, line.time)
			// Truncating minutes rather than rounding them keeps the seconds field under 60.
			let minutes = Int(total) / 60
			let seconds = total - Double(minutes * 60)
			return String(format: "[%02d:%05.2f]%@", minutes, seconds, line.text)
		}
		.joined(separator: "\n")
	}
}
