//
//  LyricsResolverTests.swift
//  TidalSwiftLibTests
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import XCTest
import LRCParser
@testable import TidalSwiftLib

@MainActor
final class LyricsResolverTests: XCTestCase {
	private struct DecisionCase {
		let tidal: TidalLyrics?
		let lrclib: LRCLIBLyrics?
		let flag: Bool
		let source: LyricsSource?
		let lines: Int
		let plain: String?
	}

	private let tidalLRC = TidalLyrics(lrc: "[00:01.00]Tidal line", plain: "Tidal plain")
	private let tidalPlain = TidalLyrics(lrc: nil, plain: "Tidal plain")
	private let lrclibLRC = LRCLIBLyrics(lrc: "[00:02.00]LRCLIB line", plain: "LRCLIB plain")
	private let lrclibPlain = LRCLIBLyrics(lrc: nil, plain: "LRCLIB plain")

	private func query(trackId: Int) -> LyricsQuery {
		LyricsQuery(trackId: trackId, title: "T", artistName: "A", albumName: "B", duration: 100)
	}

	func testDecisionMatrix() {
		let cases: [DecisionCase] = [
			// Tidal LRC always wins, flag on or off.
			DecisionCase(tidal: tidalLRC, lrclib: lrclibLRC, flag: true, source: .tidal, lines: 1, plain: "Tidal plain"),
			DecisionCase(tidal: tidalLRC, lrclib: lrclibLRC, flag: false, source: .tidal, lines: 1, plain: "Tidal plain"),
			DecisionCase(tidal: tidalLRC, lrclib: lrclibPlain, flag: true, source: .tidal, lines: 1, plain: "Tidal plain"),
			DecisionCase(tidal: tidalLRC, lrclib: nil, flag: true, source: .tidal, lines: 1, plain: "Tidal plain"),
			DecisionCase(tidal: tidalLRC, lrclib: nil, flag: false, source: .tidal, lines: 1, plain: "Tidal plain"),
			// Tidal plain only: LRCLIB LRC wins, otherwise Tidal's plain.
			DecisionCase(tidal: tidalPlain, lrclib: lrclibLRC, flag: true, source: .lrclib, lines: 1, plain: "LRCLIB plain"),
			DecisionCase(tidal: tidalPlain, lrclib: lrclibPlain, flag: true, source: .tidal, lines: 0, plain: "Tidal plain"),
			DecisionCase(tidal: tidalPlain, lrclib: nil, flag: true, source: .tidal, lines: 0, plain: "Tidal plain"),
			DecisionCase(tidal: tidalPlain, lrclib: lrclibLRC, flag: false, source: .tidal, lines: 0, plain: "Tidal plain"),
			DecisionCase(tidal: tidalPlain, lrclib: lrclibPlain, flag: false, source: .tidal, lines: 0, plain: "Tidal plain"),
			DecisionCase(tidal: tidalPlain, lrclib: nil, flag: false, source: .tidal, lines: 0, plain: "Tidal plain"),
			// Tidal nothing: LRCLIB only when the flag is on.
			DecisionCase(tidal: nil, lrclib: lrclibLRC, flag: true, source: .lrclib, lines: 1, plain: "LRCLIB plain"),
			DecisionCase(tidal: nil, lrclib: lrclibPlain, flag: true, source: .lrclib, lines: 0, plain: "LRCLIB plain"),
			DecisionCase(tidal: nil, lrclib: nil, flag: true, source: nil, lines: 0, plain: nil),
			DecisionCase(tidal: nil, lrclib: lrclibLRC, flag: false, source: nil, lines: 0, plain: nil),
			DecisionCase(tidal: nil, lrclib: lrclibPlain, flag: false, source: nil, lines: 0, plain: nil),
			DecisionCase(tidal: nil, lrclib: nil, flag: false, source: nil, lines: 0, plain: nil)
		]

		for testCase in cases {
			let result = LyricsResolver.decide(tidal: testCase.tidal, lrclib: testCase.lrclib, preferLRCLIB: testCase.flag)
			XCTAssertEqual(result?.source, testCase.source, "source for \(testCase)")
			XCTAssertEqual(result?.lines.count ?? 0, testCase.lines, "line count for \(testCase)")
			XCTAssertEqual(result?.plainText, testCase.plain, "plain text for \(testCase)")
		}
	}

	func testDecisionParsesLRCIntoLines() {
		let result = LyricsResolver.decide(tidal: tidalLRC, lrclib: nil, preferLRCLIB: true)
		XCTAssertEqual(result?.lines.first?.time, 1)
		XCTAssertEqual(result?.lines.first?.text, "Tidal line")
	}

	func testEmptyStringsAreTreatedAsMissing() {
		let result = LyricsResolver.decide(
			tidal: TidalLyrics(lrc: "", plain: "   "),
			lrclib: LRCLIBLyrics(lrc: "\n", plain: ""),
			preferLRCLIB: true
		)
		XCTAssertNil(result)
	}

	func testOrchestrationDoesNotAskLRCLIBWhenTidalHasLRC() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in self.tidalLRC },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return self.lrclibLRC
			}
		)

		let result = await resolver.lyrics(for: query(trackId: 1), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 0)
		XCTAssertEqual(result?.source, .tidal)
	}

	func testOrchestrationDoesNotAskLRCLIBWhenFlagIsOff() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in self.tidalPlain },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return self.lrclibLRC
			}
		)

		let result = await resolver.lyrics(for: query(trackId: 2), preferLRCLIB: false)

		XCTAssertEqual(lrclibCalls, 0)
		XCTAssertEqual(result?.source, .tidal)
		XCTAssertEqual(result?.plainText, "Tidal plain")
	}

	func testOrchestrationAsksLRCLIBForPlainOnlyTidalLyrics() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in self.tidalPlain },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return self.lrclibLRC
			}
		)

		let result = await resolver.lyrics(for: query(trackId: 3), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 1)
		XCTAssertEqual(result?.source, .lrclib)
		XCTAssertEqual(result?.lines.first?.text, "LRCLIB line")
	}

	func testOrchestrationAsksLRCLIBWhenTidalHasNothing() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in nil },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return self.lrclibPlain
			}
		)

		let result = await resolver.lyrics(for: query(trackId: 4), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 1)
		XCTAssertEqual(result?.source, .lrclib)
		XCTAssertEqual(result?.plainText, "LRCLIB plain")
	}

	func testOrchestrationReturnsNilWhenNothingFound() async {
		let resolver = LyricsResolver(
			tidalFetcher: { _ in nil },
			lrclibFetcher: { _, _, _, _ in nil }
		)

		let result = await resolver.lyrics(for: query(trackId: 5), preferLRCLIB: true)

		XCTAssertNil(result)
	}

	func testCacheAvoidsRefetch() async {
		var tidalCalls = 0
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return self.tidalPlain
			},
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return self.lrclibLRC
			}
		)

		_ = await resolver.lyrics(for: query(trackId: 6), preferLRCLIB: true)
		_ = await resolver.lyrics(for: query(trackId: 6), preferLRCLIB: true)

		XCTAssertEqual(tidalCalls, 1)
		XCTAssertEqual(lrclibCalls, 1)
	}

	func testCacheIsSharedAcrossResolvers() async {
		var tidalCalls = 0
		let cache = LyricsCache()
		let first = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return self.tidalLRC
			},
			lrclibFetcher: { _, _, _, _ in nil },
			cache: cache
		)
		let second = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return self.tidalLRC
			},
			lrclibFetcher: { _, _, _, _ in nil },
			cache: cache
		)

		_ = await first.lyrics(for: query(trackId: 8), preferLRCLIB: true)
		_ = await second.lyrics(for: query(trackId: 8), preferLRCLIB: true)

		XCTAssertEqual(tidalCalls, 1)
	}

	func testCacheRespectsFallbackSetting() async {		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in self.tidalPlain },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return self.lrclibLRC
			}
		)

		let off = await resolver.lyrics(for: query(trackId: 7), preferLRCLIB: false)
		XCTAssertEqual(off?.source, .tidal)
		XCTAssertEqual(lrclibCalls, 0)

		let on = await resolver.lyrics(for: query(trackId: 7), preferLRCLIB: true)
		XCTAssertEqual(on?.source, .lrclib)
		XCTAssertEqual(lrclibCalls, 1)
	}
}
