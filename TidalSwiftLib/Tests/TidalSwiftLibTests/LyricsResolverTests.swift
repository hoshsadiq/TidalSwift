//
//  LyricsResolverTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
import LRCParser
@testable import TidalSwiftLib

@MainActor
final class LyricsResolverTests: XCTestCase {
	/// What `decide` should answer, without spelling out a whole result.
	private enum Expectation {
		case found(LyricsSource, lines: Int, plain: String?)
		case notFound
		case failed
	}

	private struct DecisionCase {
		let tidal: LyricsOutcome<TidalLyrics>
		let lrclib: LyricsOutcome<LRCLIBLyrics>
		let flag: Bool
		let expected: Expectation
	}

	private let tidalLRC = TidalLyrics(lrc: "[00:01.00]Tidal line", plain: "Tidal plain")
	private let tidalPlain = TidalLyrics(lrc: nil, plain: "Tidal plain")
	private let lrclibLRC = LRCLIBLyrics(lrc: "[00:02.00]LRCLIB line", plain: "LRCLIB plain")
	private let lrclibPlain = LRCLIBLyrics(lrc: nil, plain: "LRCLIB plain")

	private func query(trackId: Int) -> LyricsQuery {
		LyricsQuery(trackId: trackId, title: "T", artistName: "A", albumName: "B", duration: 100)
	}

	private func assertOutcome(
		_ outcome: LyricsOutcome<LyricsResult>,
		matches expectation: Expectation,
		_ message: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		switch (outcome, expectation) {
		case (.found(let result), .found(let source, let lines, let plain)):
			XCTAssertEqual(result.source, source, message, file: file, line: line)
			XCTAssertEqual(result.lines.count, lines, message, file: file, line: line)
			XCTAssertEqual(result.plainText, plain, message, file: file, line: line)
		case (.notFound, .notFound), (.failed, .failed):
			break
		default:
			XCTFail("\(message): got \(outcome), wanted \(expectation)", file: file, line: line)
		}
	}

	// MARK: - Precedence

	func testDecisionMatrix() {
		let cases: [DecisionCase] = [
			// Tidal LRC always wins, flag on or off.
			DecisionCase(tidal: .found(tidalLRC), lrclib: .found(lrclibLRC), flag: true, expected: .found(.tidal, lines: 1, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalLRC), lrclib: .found(lrclibLRC), flag: false, expected: .found(.tidal, lines: 1, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalLRC), lrclib: .found(lrclibPlain), flag: true, expected: .found(.tidal, lines: 1, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalLRC), lrclib: .notFound, flag: true, expected: .found(.tidal, lines: 1, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalLRC), lrclib: .notFound, flag: false, expected: .found(.tidal, lines: 1, plain: "Tidal plain")),
			// Tidal plain only: LRCLIB LRC wins, otherwise Tidal's plain.
			DecisionCase(tidal: .found(tidalPlain), lrclib: .found(lrclibLRC), flag: true, expected: .found(.lrclib, lines: 1, plain: "LRCLIB plain")),
			DecisionCase(tidal: .found(tidalPlain), lrclib: .found(lrclibPlain), flag: true, expected: .found(.tidal, lines: 0, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalPlain), lrclib: .notFound, flag: true, expected: .found(.tidal, lines: 0, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalPlain), lrclib: .found(lrclibLRC), flag: false, expected: .found(.tidal, lines: 0, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalPlain), lrclib: .found(lrclibPlain), flag: false, expected: .found(.tidal, lines: 0, plain: "Tidal plain")),
			DecisionCase(tidal: .found(tidalPlain), lrclib: .notFound, flag: false, expected: .found(.tidal, lines: 0, plain: "Tidal plain")),
			// Tidal nothing: LRCLIB only when the flag is on.
			DecisionCase(tidal: .notFound, lrclib: .found(lrclibLRC), flag: true, expected: .found(.lrclib, lines: 1, plain: "LRCLIB plain")),
			DecisionCase(tidal: .notFound, lrclib: .found(lrclibPlain), flag: true, expected: .found(.lrclib, lines: 0, plain: "LRCLIB plain")),
			DecisionCase(tidal: .notFound, lrclib: .notFound, flag: true, expected: .notFound),
			DecisionCase(tidal: .notFound, lrclib: .found(lrclibLRC), flag: false, expected: .notFound),
			DecisionCase(tidal: .notFound, lrclib: .found(lrclibPlain), flag: false, expected: .notFound),
			DecisionCase(tidal: .notFound, lrclib: .notFound, flag: false, expected: .notFound)
		]

		for (index, testCase) in cases.enumerated() {
			let outcome = LyricsResolver.decide(
				tidal: testCase.tidal,
				lrclib: testCase.lrclib,
				preferLRCLIB: testCase.flag
			)
			assertOutcome(outcome, matches: testCase.expected, "matrix row \(index)")
		}
	}

	func testDecisionParsesLRCIntoLines() {
		let outcome = LyricsResolver.decide(tidal: .found(tidalLRC), lrclib: .notFound, preferLRCLIB: true)
		guard case .found(let result) = outcome else {
			return XCTFail("expected a result, got \(outcome)")
		}
		XCTAssertEqual(result.lines.first?.time, 1)
		XCTAssertEqual(result.lines.first?.text, "Tidal line")
	}

	func testEmptyStringsAreTreatedAsMissing() {
		let outcome = LyricsResolver.decide(
			tidal: .found(TidalLyrics(lrc: "", plain: "   ")),
			lrclib: .found(LRCLIBLyrics(lrc: "\n", plain: "")),
			preferLRCLIB: true
		)
		XCTAssertEqual(outcome, .notFound)
	}

	// MARK: - Failure versus miss

	func testFailedFallbackIsAFailureAndNotAMiss() {
		// The reported shape: Tidal genuinely has nothing, LRCLIB drops the request.
		let outcome = LyricsResolver.decide(tidal: .notFound, lrclib: .failed, preferLRCLIB: true)
		XCTAssertEqual(outcome, .failed)
	}

	func testBothProvidersMissingIsAMiss() {
		let outcome = LyricsResolver.decide(tidal: .notFound, lrclib: .notFound, preferLRCLIB: true)
		XCTAssertEqual(outcome, .notFound)
	}

	func testFailedTidalIsAFailureWhenTheFallbackIsOff() {
		let outcome = LyricsResolver.decide(tidal: .failed, lrclib: .notFound, preferLRCLIB: false)
		XCTAssertEqual(outcome, .failed)
	}

	func testUnconsultedFallbackCannotFailTheLookup() {
		// LRCLIB is never asked with the flag off, so its state must not leak in.
		let outcome = LyricsResolver.decide(tidal: .notFound, lrclib: .failed, preferLRCLIB: false)
		XCTAssertEqual(outcome, .notFound)
	}

	func testBothProvidersFailingIsAFailure() {
		let outcome = LyricsResolver.decide(tidal: .failed, lrclib: .failed, preferLRCLIB: true)
		XCTAssertEqual(outcome, .failed)
	}

	func testResultBeatsAFailureElsewhere() {
		let fromTidal = LyricsResolver.decide(tidal: .found(tidalLRC), lrclib: .failed, preferLRCLIB: true)
		assertOutcome(fromTidal, matches: .found(.tidal, lines: 1, plain: "Tidal plain"), "tidal LRC with a failed fallback")

		let tidalPlainBeatsFailedFallback = LyricsResolver.decide(
			tidal: .found(tidalPlain),
			lrclib: .failed,
			preferLRCLIB: true
		)
		assertOutcome(tidalPlainBeatsFailedFallback, matches: .found(.tidal, lines: 0, plain: "Tidal plain"), "tidal plain with a failed fallback")

		let fromLRCLIB = LyricsResolver.decide(tidal: .failed, lrclib: .found(lrclibPlain), preferLRCLIB: true)
		assertOutcome(fromLRCLIB, matches: .found(.lrclib, lines: 0, plain: "LRCLIB plain"), "failed tidal with LRCLIB plain")
	}

	// MARK: - Orchestration

	func testOrchestrationDoesNotAskLRCLIBWhenTidalHasLRC() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .found(self.tidalLRC) },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .found(self.lrclibLRC)
			}
		)

		let outcome = await resolver.lyrics(for: query(trackId: 1), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 0)
		assertOutcome(outcome, matches: .found(.tidal, lines: 1, plain: "Tidal plain"), "tidal LRC wins")
	}

	func testOrchestrationDoesNotAskLRCLIBWhenFlagIsOff() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .found(self.tidalPlain) },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .found(self.lrclibLRC)
			}
		)

		let outcome = await resolver.lyrics(for: query(trackId: 2), preferLRCLIB: false)

		XCTAssertEqual(lrclibCalls, 0)
		assertOutcome(outcome, matches: .found(.tidal, lines: 0, plain: "Tidal plain"), "flag off keeps Tidal plain")
	}

	func testOrchestrationAsksLRCLIBForPlainOnlyTidalLyrics() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .found(self.tidalPlain) },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .found(self.lrclibLRC)
			}
		)

		let outcome = await resolver.lyrics(for: query(trackId: 3), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 1)
		assertOutcome(outcome, matches: .found(.lrclib, lines: 1, plain: "LRCLIB plain"), "LRCLIB LRC beats Tidal plain")
	}

	func testOrchestrationAsksLRCLIBWhenTidalHasNothing() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .notFound },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .found(self.lrclibPlain)
			}
		)

		let outcome = await resolver.lyrics(for: query(trackId: 4), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 1)
		assertOutcome(outcome, matches: .found(.lrclib, lines: 0, plain: "LRCLIB plain"), "LRCLIB serves the miss")
	}

	func testOrchestrationReportsAMissWhenNothingIsFound() async {
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .notFound },
			lrclibFetcher: { _, _, _, _ in .notFound }
		)

		let outcome = await resolver.lyrics(for: query(trackId: 5), preferLRCLIB: true)

		XCTAssertEqual(outcome, .notFound)
	}

	func testOrchestrationReportsADroppedRequestAsAFailure() async {
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .notFound },
			lrclibFetcher: { _, _, _, _ in .failed }
		)

		let outcome = await resolver.lyrics(for: query(trackId: 6), preferLRCLIB: true)

		XCTAssertEqual(outcome, .failed)
	}

	func testOrchestrationLetsLRCLIBRescueAFailedTidalLeg() async {
		// The consult condition must key on whether Tidal has LRC, not on whether
		// the Tidal lookup failed, or a drop would hide LRCLIB's lyrics.
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .failed },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .found(self.lrclibLRC)
			}
		)

		let outcome = await resolver.lyrics(for: query(trackId: 14), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 1)
		assertOutcome(outcome, matches: .found(.lrclib, lines: 1, plain: "LRCLIB plain"), "LRCLIB rescues a failed Tidal leg")
	}

	func testAFailureIsNotCachedSoAskingAgainRefetches() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .notFound },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				// The dropped request the retry button is there to recover from.
				return lrclibCalls == 1 ? .failed : .found(self.lrclibLRC)
			}
		)

		let first = await resolver.lyrics(for: query(trackId: 7), preferLRCLIB: true)
		let second = await resolver.lyrics(for: query(trackId: 7), preferLRCLIB: true)

		XCTAssertEqual(first, .failed)
		XCTAssertEqual(lrclibCalls, 2)
		assertOutcome(second, matches: .found(.lrclib, lines: 1, plain: "LRCLIB plain"), "the second ask succeeds")
	}

	func testAMissIsNotCachedSoAskingAgainRefetches() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .notFound },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .notFound
			}
		)

		_ = await resolver.lyrics(for: query(trackId: 9), preferLRCLIB: true)
		_ = await resolver.lyrics(for: query(trackId: 9), preferLRCLIB: true)

		XCTAssertEqual(lrclibCalls, 2)
	}

	func testTimedTextWithNoTimestampsAndNoPlainTextIsAMiss() async {
		// A provider can hand back LRC that parses to nothing. That is nothing to
		// show, so it must not be stored as a result the retry button would replay.
		let unparseable = TidalLyrics(lrc: "no timestamps here", plain: nil)
		var tidalCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return .found(unparseable)
			},
			lrclibFetcher: { _, _, _, _ in .notFound }
		)

		let first = await resolver.lyrics(for: query(trackId: 13), preferLRCLIB: true)
		let second = await resolver.lyrics(for: query(trackId: 13), preferLRCLIB: true)

		XCTAssertEqual(first, .notFound)
		XCTAssertEqual(second, .notFound)
		XCTAssertEqual(tidalCalls, 2)
	}

	// MARK: - Cache

	func testCacheAvoidsRefetch() async {
		var tidalCalls = 0
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return .found(self.tidalPlain)
			},
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .found(self.lrclibLRC)
			}
		)

		_ = await resolver.lyrics(for: query(trackId: 10), preferLRCLIB: true)
		_ = await resolver.lyrics(for: query(trackId: 10), preferLRCLIB: true)

		XCTAssertEqual(tidalCalls, 1)
		XCTAssertEqual(lrclibCalls, 1)
	}

	func testCacheIsSharedAcrossResolvers() async {
		var tidalCalls = 0
		let cache = LyricsCache()
		let first = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return .found(self.tidalLRC)
			},
			lrclibFetcher: { _, _, _, _ in .notFound },
			cache: cache
		)
		let second = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return .found(self.tidalLRC)
			},
			lrclibFetcher: { _, _, _, _ in .notFound },
			cache: cache
		)

		_ = await first.lyrics(for: query(trackId: 11), preferLRCLIB: true)
		_ = await second.lyrics(for: query(trackId: 11), preferLRCLIB: true)

		XCTAssertEqual(tidalCalls, 1)
	}

	// MARK: - Disk cache

	/// A throwaway lyrics folder, so a test never touches the real one.
	private func temporaryRoot() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("TidalSwiftTests-lyrics-\(UUID().uuidString)", isDirectory: true)
	}

	private func storedFileNames(in root: URL) -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
	}

	func testAFoundResultIsServedFromDiskToALaterResolver() async {
		let root = temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let disk = LyricsDiskCache(directory: root)

		let first = LyricsResolver(
			tidalFetcher: { _ in .found(self.tidalLRC) },
			lrclibFetcher: { _, _, _, _ in .notFound },
			cache: LyricsCache(),
			diskCache: disk
		)
		_ = await first.lyrics(for: query(trackId: 30), preferLRCLIB: true)

		// A fresh memory cache stands in for the next launch.
		let memory = LyricsCache()
		var tidalCalls = 0
		let second = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return .failed
			},
			lrclibFetcher: { _, _, _, _ in .notFound },
			cache: memory,
			diskCache: disk
		)
		let outcome = await second.lyrics(for: query(trackId: 30), preferLRCLIB: true)

		XCTAssertEqual(tidalCalls, 0, "the disk answers, so neither provider is asked")
		assertOutcome(outcome, matches: .found(.tidal, lines: 1, plain: "Tidal plain"), "the disk serves the second resolver")
		guard case .hit = await memory.lookup(trackId: 30, preferLRCLIB: true) else {
			return XCTFail("a disk hit should be promoted into the memory cache")
		}
	}

	func testADiskResultUnderTheOtherPreferenceIsIgnored() async {
		let root = temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let disk = LyricsDiskCache(directory: root)
		let resolved = LyricsResult(lines: [], plainText: "plain", source: .tidal)
		await disk.store(resolved, trackId: 31, preferLRCLIB: true)

		var tidalCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in
				tidalCalls += 1
				return .found(self.tidalPlain)
			},
			lrclibFetcher: { _, _, _, _ in .notFound },
			cache: LyricsCache(),
			diskCache: disk
		)
		_ = await resolver.lyrics(for: query(trackId: 31), preferLRCLIB: false)

		XCTAssertEqual(tidalCalls, 1)
	}

	func testAMissIsNotWrittenToDisk() async {
		let root = temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .notFound },
			lrclibFetcher: { _, _, _, _ in .notFound },
			cache: LyricsCache(),
			diskCache: LyricsDiskCache(directory: root)
		)

		_ = await resolver.lyrics(for: query(trackId: 32), preferLRCLIB: true)

		XCTAssertEqual(storedFileNames(in: root), [])
	}

	func testAFailureIsNotWrittenToDisk() async {
		let root = temporaryRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .failed },
			lrclibFetcher: { _, _, _, _ in .failed },
			cache: LyricsCache(),
			diskCache: LyricsDiskCache(directory: root)
		)

		_ = await resolver.lyrics(for: query(trackId: 33), preferLRCLIB: true)

		XCTAssertEqual(storedFileNames(in: root), [])
	}

	func testCacheRespectsFallbackSetting() async {
		var lrclibCalls = 0
		let resolver = LyricsResolver(
			tidalFetcher: { _ in .found(self.tidalPlain) },
			lrclibFetcher: { _, _, _, _ in
				lrclibCalls += 1
				return .found(self.lrclibLRC)
			}
		)

		let off = await resolver.lyrics(for: query(trackId: 12), preferLRCLIB: false)
		assertOutcome(off, matches: .found(.tidal, lines: 0, plain: "Tidal plain"), "flag off")
		XCTAssertEqual(lrclibCalls, 0)

		let on = await resolver.lyrics(for: query(trackId: 12), preferLRCLIB: true)
		assertOutcome(on, matches: .found(.lrclib, lines: 1, plain: "LRCLIB plain"), "flag on")
		XCTAssertEqual(lrclibCalls, 1)
	}
}
