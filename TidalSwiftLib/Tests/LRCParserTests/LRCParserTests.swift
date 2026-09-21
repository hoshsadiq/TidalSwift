//
//  LRCParserTests.swift
//  LRCParserTests
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
import LRCParser

final class LRCParserTests: XCTestCase {
	func testParsesBasicLines() {
		let lrc = """
		[00:12.00] First line
		[00:15.50] Second line
		"""

		XCTAssertEqual(LRCParser.parse(lrc), [
			LyricLine(time: 12, text: "First line"),
			LyricLine(time: 15.5, text: "Second line")
		])
	}

	func testParsesMultipleTimestampsOnOneLine() {
		let lines = LRCParser.parse("[00:12.00][01:20.00] Repeated")

		XCTAssertEqual(lines, [
			LyricLine(time: 12, text: "Repeated"),
			LyricLine(time: 80, text: "Repeated")
		])
	}

	func testParsesMultipleTimestampsSeparatedByWhitespace() {
		let lines = LRCParser.parse("[00:12.00] [01:20.00] Repeated")

		XCTAssertEqual(lines.map(\.time), [12, 80])
		XCTAssertEqual(lines.map(\.text), ["Repeated", "Repeated"])
	}

	func testParsesTimestampFormats() {
		let lrc = """
		[00:05] a
		[00:06.5] b
		[00:07.25] c
		[00:08.125] d
		"""

		XCTAssertEqual(LRCParser.parse(lrc).map(\.time), [5, 6.5, 7.25, 8.125])
	}

	func testParsesMinutesBeyondFiftyNine() {
		let lines = LRCParser.parse("[75:30.00] Long track")

		XCTAssertEqual(lines, [LyricLine(time: 75 * 60 + 30, text: "Long track")])
	}

	func testAppliesPositiveOffset() {
		let lrc = """
		[offset:+500]
		[00:10.00] a
		"""

		XCTAssertEqual(LRCParser.parse(lrc).map(\.time), [10.5])
	}

	func testAppliesNegativeOffset() {
		let lrc = """
		[offset:-500]
		[00:10.00] a
		"""

		XCTAssertEqual(LRCParser.parse(lrc).map(\.time), [9.5])
	}

	func testAppliesUnsignedOffsetAsPositive() {
		let lrc = """
		[offset:500]
		[00:10.00] a
		"""

		XCTAssertEqual(LRCParser.parse(lrc).map(\.time), [10.5])
	}

	func testOffsetAppliesToLinesBeforeTheTag() {
		let lrc = """
		[00:10.00] a
		[offset:+1000]
		[00:20.00] b
		"""

		XCTAssertEqual(LRCParser.parse(lrc).map(\.time), [11, 21])
	}

	func testOffsetClampsTimesAtZero() {
		let lrc = """
		[offset:-5000]
		[00:01.00] a
		"""

		XCTAssertEqual(LRCParser.parse(lrc).map(\.time), [0])
	}

	func testIgnoresMalformedOffset() {
		let lrc = """
		[offset:abc]
		[00:10.00] a
		"""

		XCTAssertEqual(LRCParser.parse(lrc).map(\.time), [10])
	}

	func testSkipsMetadataTags() {
		let lrc = """
		[ar:Artist]
		[ti:Title]
		[al:Album]
		[by:Author]
		[re:Editor]
		[ve:1.0]
		[length:03:45]
		[00:10.00] a
		"""

		XCTAssertEqual(LRCParser.parse(lrc), [LyricLine(time: 10, text: "a")])
	}

	func testSkipsBlankLines() {
		let lrc = "\n\n[00:10.00] a\n   \n\t\n[00:20.00] b\n\n"

		XCTAssertEqual(LRCParser.parse(lrc).map(\.text), ["a", "b"])
	}

	func testSkipsMalformedLines() {
		let lrc = """
		[00:xx.00] bad
		[abc] bad
		[00:75.00] bad
		[00:12.00 unclosed
		not a timestamp
		[00:10.00] good
		"""

		XCTAssertEqual(LRCParser.parse(lrc), [LyricLine(time: 10, text: "good")])
	}

	func testReturnsEmptyForPlainText() {
		let lrc = """
		Just some plain lyrics
		with no timestamps at all
		"""

		XCTAssertTrue(LRCParser.parse(lrc).isEmpty)
	}

	func testReturnsEmptyForEmptyInput() {
		XCTAssertTrue(LRCParser.parse("").isEmpty)
		XCTAssertTrue(LRCParser.parse("   \n\t\n").isEmpty)
	}

	func testHandlesCRLFLineEndings() {
		let lines = LRCParser.parse("[00:10.00] a\r\n[00:20.00] b\r\n")

		XCTAssertEqual(lines, [
			LyricLine(time: 10, text: "a"),
			LyricLine(time: 20, text: "b")
		])
	}

	func testSortsOutOfOrderTimestamps() {
		let lines = LRCParser.parse("[01:20.00][00:12.00] Both")

		XCTAssertEqual(lines.map(\.time), [12, 80])
	}

	func testKeepsTimestampedEmptyTextLines() {
		let lines = LRCParser.parse("[00:10.00]\n[00:20.00] b")

		XCTAssertEqual(lines, [
			LyricLine(time: 10, text: ""),
			LyricLine(time: 20, text: "b")
		])
	}

	func testPreservesBracketsInText() {
		let lines = LRCParser.parse("[00:10.00] Hello [world]")

		XCTAssertEqual(lines, [LyricLine(time: 10, text: "Hello [world]")])
	}

	func testIgnoresMetadataSharingALineWithATimestamp() {
		let lines = LRCParser.parse("[ar:Artist][00:10.00] a")

		XCTAssertEqual(lines, [LyricLine(time: 10, text: "a")])
	}

	func testParsesRealisticDocument() {
		let lrc = """
		[ar:Some Artist]
		[ti:Some Title]
		[al:Some Album]
		[length:03:20]
		[offset:-200]
		[00:00.00]
		[00:12.34] First line
		[00:15.00][01:20.00] Chorus line
		[00:18.50] Second line
		"""

		let lines = LRCParser.parse(lrc)

		XCTAssertEqual(lines.count, 5)
		XCTAssertEqual(lines[0], LyricLine(time: 0, text: ""))
		XCTAssertEqual(lines[1].text, "First line")
		XCTAssertEqual(lines[1].time, 12.34 - 0.2, accuracy: 0.0001)
		XCTAssertEqual(lines[2].text, "Chorus line")
		XCTAssertEqual(lines[2].time, 15 - 0.2, accuracy: 0.0001)
		XCTAssertEqual(lines[3].text, "Second line")
		XCTAssertEqual(lines[3].time, 18.5 - 0.2, accuracy: 0.0001)
		XCTAssertEqual(lines[4].text, "Chorus line")
		XCTAssertEqual(lines[4].time, 80 - 0.2, accuracy: 0.0001)
	}

	// MARK: - currentIndex(at:in:)

	func testCurrentIndexBeforeFirstLineIsNil() {
		let lines = [
			LyricLine(time: 10, text: "a"),
			LyricLine(time: 20, text: "b")
		]

		XCTAssertNil(LyricLine.currentIndex(at: 9.99, in: lines))
	}

	func testCurrentIndexOnExactLineTime() {
		let lines = [
			LyricLine(time: 10, text: "a"),
			LyricLine(time: 20, text: "b"),
			LyricLine(time: 30, text: "c")
		]

		XCTAssertEqual(LyricLine.currentIndex(at: 10, in: lines), 0)
		XCTAssertEqual(LyricLine.currentIndex(at: 20, in: lines), 1)
		XCTAssertEqual(LyricLine.currentIndex(at: 30, in: lines), 2)
	}

	func testCurrentIndexBetweenLines() {
		let lines = [
			LyricLine(time: 10, text: "a"),
			LyricLine(time: 20, text: "b"),
			LyricLine(time: 30, text: "c")
		]

		XCTAssertEqual(LyricLine.currentIndex(at: 15, in: lines), 0)
		XCTAssertEqual(LyricLine.currentIndex(at: 25, in: lines), 1)
	}

	func testCurrentIndexAfterLastLine() {
		let lines = [
			LyricLine(time: 10, text: "a"),
			LyricLine(time: 20, text: "b")
		]

		XCTAssertEqual(LyricLine.currentIndex(at: 1000, in: lines), 1)
	}

	func testCurrentIndexWithDuplicateTimesReturnsLastMatch() {
		let lines = [
			LyricLine(time: 10, text: "a"),
			LyricLine(time: 10, text: "b")
		]

		XCTAssertEqual(LyricLine.currentIndex(at: 10, in: lines), 1)
	}

	func testCurrentIndexForEmptyLinesIsNil() {
		XCTAssertNil(LyricLine.currentIndex(at: 10, in: []))
	}
}
