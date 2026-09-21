//
//  LRCParser.swift
//  LRCParser
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import Foundation

/// A single timed lyric line parsed from an LRC document.
public struct LyricLine: Equatable, Sendable {
	/// Playback time of the line in seconds, after applying any `[offset:]` tag.
	public let time: TimeInterval
	/// Lyric text with surrounding whitespace trimmed. May be empty for
	/// timestamped instrumental gaps.
	public let text: String

	public init(time: TimeInterval, text: String) {
		self.time = time
		self.text = text
	}
}

extension LyricLine {
	/// Index of the last line whose time is at or before `time`.
	///
	/// Returns `nil` when `time` precedes every line or `lines` is empty.
	/// Relies on `lines` being sorted by time, as returned by `LRCParser.parse(_:)`.
	public static func currentIndex(at time: TimeInterval, in lines: [LyricLine]) -> Int? {
		var low = 0
		var high = lines.count - 1
		var result: Int?

		while low <= high {
			let mid = (low + high) / 2
			if lines[mid].time <= time {
				result = mid
				low = mid + 1
			} else {
				high = mid - 1
			}
		}

		return result
	}
}

/// Parser for the LRC timestamped-lyrics format.
///
/// Deliberately lenient: malformed lines are skipped instead of throwing, so a
/// partially broken document still yields every line it can.
public enum LRCParser {
	/// Parses an LRC document into timed lyric lines, sorted by time.
	///
	/// Handles `mm:ss`, `mm:ss.x`, `mm:ss.xx` and `mm:ss.xxx` timestamps (minutes
	/// may exceed 59), multiple timestamps on one line (`[00:12.00][01:20.00] text`),
	/// and the `[offset:±ms]` tag, which is applied to every line (`+` shifts later,
	/// `-` earlier, results clamped at zero). Metadata tags (`[ar:]`, `[ti:]`, `[al:]`,
	/// `[by:]`, `[re:]`, `[ve:]`, `[length:]`) and blank or malformed lines are skipped.
	///
	/// Returns an empty array when the input contains no timestamps (plain text),
	/// letting callers fall back to a plain-text rendering path.
	public static func parse(_ lrc: String) -> [LyricLine] {
		let document = lrc.hasPrefix("\u{FEFF}") ? String(lrc.dropFirst()) : lrc
		let rawLines = document.components(separatedBy: .newlines)
		let offset = offsetSeconds(in: rawLines)

		var lines: [LyricLine] = []
		for rawLine in rawLines {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard !line.isEmpty else { continue }

			let (timestamps, text) = split(line)
			guard !timestamps.isEmpty else { continue }

			for timestamp in timestamps {
				lines.append(LyricLine(time: max(0, timestamp + offset), text: text))
			}
		}

		// Multi-timestamp lines can emit out of order, and `currentIndex(at:in:)`
		// relies on ascending times, so sort stably by time.
		return lines.enumerated()
			.sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
			.map(\.element)
	}

	/// Splits a line into its leading timestamps and the remaining text.
	///
	/// Leading non-timestamp tags are ignored (metadata may share a line with a
	/// timestamp); once a timestamp has been seen, a non-timestamp tag ends the
	/// scan and stays part of the text.
	private static func split(_ line: String) -> (timestamps: [TimeInterval], text: String) {
		var timestamps: [TimeInterval] = []
		var remainder = Substring(line)

		while true {
			remainder = remainder.drop(while: \.isWhitespace)
			guard remainder.first == "[" else { break }
			guard let closing = remainder.firstIndex(of: "]") else { break }
			let tag = remainder[remainder.index(after: remainder.startIndex)..<closing]

			if let time = timestamp(from: tag) {
				timestamps.append(time)
			} else if !timestamps.isEmpty {
				break
			}

			remainder = remainder[remainder.index(after: closing)...]
		}

		return (timestamps, remainder.trimmingCharacters(in: .whitespaces))
	}

	/// Parses a `mm:ss`, `mm:ss.x`, `mm:ss.xx` or `mm:ss.xxx` tag body into seconds.
	private static func timestamp(from tag: Substring) -> TimeInterval? {
		let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
		guard parts.count == 2 else { return nil }
		guard let minutes = Int(parts[0]), minutes >= 0 else { return nil }

		let secondParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
		guard secondParts.count <= 2 else { return nil }
		guard let seconds = Int(secondParts[0]), seconds >= 0, seconds < 60 else { return nil }

		var fraction = 0.0
		if secondParts.count == 2 {
			let digits = secondParts[1]
			guard !digits.isEmpty, digits.count <= 3,
				  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
				  let milliseconds = Int(digits) else { return nil }
			fraction = Double(milliseconds) / pow(10, Double(digits.count))
		}

		return Double(minutes) * 60 + Double(seconds) + fraction
	}

	/// Finds the first `[offset:±ms]` tag in the document and returns its value in seconds.
	private static func offsetSeconds(in lines: [String]) -> TimeInterval {
		for line in lines {
			guard let range = line.range(of: "[offset:", options: .caseInsensitive),
				  let closing = line[range.upperBound...].firstIndex(of: "]") else { continue }
			let value = line[range.upperBound..<closing].trimmingCharacters(in: .whitespaces)
			guard let milliseconds = Int(value) else { continue }
			return TimeInterval(milliseconds) / 1000
		}
		return 0
	}
}
