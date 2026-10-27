//
//  EmbeddedLyricsTests.swift
//  TidalSwiftLibTests
//

import Foundation
import XCTest
import AVFoundation
import LRCParser
@testable import TidalSwiftLib

/// A downloaded track carries its own lyrics, so an offline play reads them from the file
/// rather than from the network or the prunable cache. These pin the write of the tag and
/// the read back, for both containers the writers produce.
final class EmbeddedLyricsTests: XCTestCase {
	private let lrc = """
	[00:01.00]First line
	[00:12.25]Second line
	[00:20.50]Third line
	"""

	private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
		try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
			"Missing fixture \(name).\(ext)"
		)
	}

	private func temporaryCopy(ofFixture name: String, extension ext: String) throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("EmbeddedLyricsTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let destination = directory.appendingPathComponent("\(name).\(ext)")
		try FileManager.default.copyItem(at: try fixtureURL(name, ext), to: destination)
		return destination
	}

	private func removeCopy(_ url: URL) {
		try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
	}

	private func tags(lyrics: String?) -> AudioTags {
		AudioTags(
			title: "Title",
			artist: "Artist",
			album: "Album",
			albumArtist: "Album Artist",
			trackNumber: 1,
			trackTotal: 10,
			discNumber: 1,
			discTotal: 1,
			releaseDate: "2026-01-01",
			copyright: nil,
			isrc: nil,
			isCompilation: false,
			isExplicit: false,
			cover: nil,
			lyrics: lyrics
		)
	}

	// MARK: - Round trip

	func testTimedLyricsSurviveAFlacRoundTrip() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(tags(lyrics: lrc), to: url)

		let read = await EmbeddedLyrics.read(at: url)

		XCTAssertEqual(read?.lines.map(\.text), ["First line", "Second line", "Third line"])
		XCTAssertEqual(read?.lines.map(\.time), [1, 12.25, 20.5])
		XCTAssertNil(read?.plainText)
		XCTAssertEqual(read?.source, .file)
	}

	func testPlainLyricsSurviveAFlacRoundTrip() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(tags(lyrics: "Just words\nand no timings"), to: url)

		let read = await EmbeddedLyrics.read(at: url)

		XCTAssertEqual(read?.lines, [])
		XCTAssertEqual(read?.plainText, "Just words\nand no timings")
	}

	func testTimedLyricsSurviveAnMP4RoundTrip() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "m4a")
		defer { removeCopy(url) }
		try await MP4TagWriter.write(tags(lyrics: lrc), to: url)

		let read = await EmbeddedLyrics.read(at: url)

		XCTAssertEqual(read?.lines.map(\.text), ["First line", "Second line", "Third line"])
		XCTAssertEqual(read?.source, .file)
	}

	// MARK: - Absence

	func testAFileWithoutLyricsReadsAsNothing() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(tags(lyrics: nil), to: url)

		let read = await EmbeddedLyrics.read(at: url)

		XCTAssertNil(read)
	}

	func testAnEmptyLyricsFieldReadsAsNothing() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(tags(lyrics: "   \n  "), to: url)

		let read = await EmbeddedLyrics.read(at: url)

		XCTAssertNil(read, "whitespace is not lyrics")
	}

	func testAnUnreadableFileReadsAsNothing() async {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("EmbeddedLyricsTests-missing-\(UUID().uuidString).flac")

		let read = await EmbeddedLyrics.read(at: url)

		XCTAssertNil(read)
	}

	// MARK: - The writer's format

	func testTheEmbeddedTextIsLRCTheParserReadsBack() {
		let lines = [LyricLine(time: 1, text: "One"), LyricLine(time: 65.5, text: "Two")]

		let text = LRCWriter.encode(lines)

		XCTAssertEqual(text, "[00:01.00]One\n[01:05.50]Two")
		XCTAssertEqual(LRCParser.parse(text), lines)
	}

	func testATimeThatRoundsUpToTheNextMinuteStaysReadable() {
		// 59.996 rounds to 60 hundredths-seconds' worth of a minute boundary; writing it as
		// `[00:60.00]` would give a document no reader accepts.
		let text = LRCWriter.encode([LyricLine(time: 59.996, text: "Edge")])

		XCTAssertEqual(text, "[01:00.00]Edge")
		XCTAssertEqual(LRCParser.parse(text).map(\.text), ["Edge"])
	}

	func testANegativeTimeIsClampedWhenWritten() {
		let text = LRCWriter.encode([LyricLine(time: -5, text: "Before the start")])

		XCTAssertEqual(text, "[00:00.00]Before the start")
	}
}
