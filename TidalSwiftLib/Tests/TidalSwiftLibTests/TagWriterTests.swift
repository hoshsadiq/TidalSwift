//
//  TagWriterTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 05.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import AVFoundation
import CryptoKit
import XCTest
@testable import TidalSwiftLib

/// Checks the download tag writers against the file formats themselves: the written files are
/// parsed here by hand (FLAC metadata blocks, MP4 atoms), never with the writers' own code, so
/// a writer bug fails the test instead of being mirrored by it.
final class TagWriterTests: XCTestCase {
	private enum ParseError: Error {
		case malformed(String)
	}

	// MARK: - Fixtures

	private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
		try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
			"Missing fixture \(name).\(ext)"
		)
	}

	private func coverData() throws -> Data {
		try Data(contentsOf: fixtureURL("coverArt", "bin"))
	}

	/// Copies a fixture into its own temporary directory, so a failing test can never tag a fixture in place.
	private func temporaryCopy(ofFixture name: String, extension ext: String) throws -> URL {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("TagWriterTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let destination = directory.appendingPathComponent("\(name).\(ext)")
		try FileManager.default.copyItem(at: try fixtureURL(name, ext), to: destination)
		return destination
	}

	private func removeCopy(_ url: URL) {
		try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
	}

	private func fullTags(cover: Data?) -> AudioTags {
		AudioTags(
			title: "Jóga (Album Version)",
			artist: "Björk",
			album: "Homogénic Live",
			albumArtist: "ALBUM",
			trackNumber: 1,
			trackTotal: 3,
			discNumber: 2,
			discTotal: 2,
			releaseDate: "1997-09-22",
			copyright: "© 1997 Björk Overseas Ltd",
			isrc: "GBBKT9700061",
			isCompilation: true,
			isExplicit: true,
			cover: cover
		)
	}

	private func emptyTags() -> AudioTags {
		AudioTags(
			title: "Title Only",
			artist: nil,
			album: "Album Only",
			albumArtist: nil,
			trackNumber: 1,
			trackTotal: nil,
			discNumber: 1,
			discTotal: nil,
			releaseDate: nil,
			copyright: nil,
			isrc: nil,
			isCompilation: false,
			isExplicit: false,
			cover: nil
		)
	}

	// MARK: - Independent FLAC parsing

	private struct FLACBlock {
		let type: UInt8
		let isLast: Bool
		let body: [UInt8]
	}

	/// Walks the FLAC metadata block chain by hand and returns the blocks plus the audio bytes after them.
	private func parseFLAC(_ data: Data) throws -> (blocks: [FLACBlock], audio: [UInt8]) {
		let bytes = [UInt8](data)
		guard bytes.count > 4, Array(bytes[0..<4]) == Array("fLaC".utf8) else {
			throw ParseError.malformed("no fLaC marker")
		}
		var offset = 4
		var blocks: [FLACBlock] = []
		var isLast = false
		while !isLast {
			guard offset + 4 <= bytes.count else {
				throw ParseError.malformed("truncated block header at \(offset)")
			}
			let header = bytes[offset]
			isLast = header & 0x80 != 0
			let type = header & 0x7F
			let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
			guard offset + 4 + length <= bytes.count else {
				throw ParseError.malformed("truncated block body at \(offset)")
			}
			blocks.append(FLACBlock(type: type, isLast: isLast, body: Array(bytes[(offset + 4)..<(offset + 4 + length)])))
			offset += 4 + length
		}
		return (blocks, Array(bytes[offset...]))
	}

	private func littleEndianUInt32(_ bytes: [UInt8], at offset: inout Int) throws -> Int {
		guard offset + 4 <= bytes.count else {
			throw ParseError.malformed("truncated u32 at \(offset)")
		}
		let value = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
		offset += 4
		return value
	}

	private func bigEndianUInt32(_ bytes: [UInt8], at offset: inout Int) throws -> Int {
		guard offset + 4 <= bytes.count else {
			throw ParseError.malformed("truncated u32 at \(offset)")
		}
		let value = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
		offset += 4
		return value
	}

	/// Parses a Vorbis comment block: little-endian lengths, `KEY=value` lines.
	private func parseVorbisComment(_ body: [UInt8]) throws -> (vendor: String, comments: [String]) {
		var offset = 0
		let vendorLength = try littleEndianUInt32(body, at: &offset)
		guard offset + vendorLength <= body.count else {
			throw ParseError.malformed("truncated vendor")
		}
		let vendor = String(decoding: body[offset..<(offset + vendorLength)], as: UTF8.self)
		offset += vendorLength
		let count = try littleEndianUInt32(body, at: &offset)
		var comments: [String] = []
		for _ in 0..<count {
			let length = try littleEndianUInt32(body, at: &offset)
			guard offset + length <= body.count else {
				throw ParseError.malformed("truncated comment")
			}
			comments.append(String(decoding: body[offset..<(offset + length)], as: UTF8.self))
			offset += length
		}
		return (vendor, comments)
	}

	/// Splits `KEY=value` on the first `=`, uppercases the key (Vorbis keys are case-insensitive).
	private func commentsByKey(_ comments: [String]) -> [String: String] {
		var result: [String: String] = [:]
		for comment in comments {
			guard let separator = comment.firstIndex(of: "=") else {
				continue
			}
			let key = comment[comment.startIndex..<separator].uppercased()
			result[key] = String(comment[comment.index(after: separator)...])
		}
		return result
	}

	private struct FLACPicture {
		let type: Int
		let mime: String
		let description: String
		let width: Int
		let height: Int
		let depth: Int
		let colors: Int
		let image: [UInt8]
	}

	/// Parses a FLAC picture block (RFC 9639 §8.6), all fields big-endian.
	private func parsePicture(_ body: [UInt8]) throws -> FLACPicture {
		var offset = 0
		let type = try bigEndianUInt32(body, at: &offset)
		let mimeLength = try bigEndianUInt32(body, at: &offset)
		guard offset + mimeLength <= body.count else {
			throw ParseError.malformed("truncated picture mime")
		}
		let mime = String(decoding: body[offset..<(offset + mimeLength)], as: UTF8.self)
		offset += mimeLength
		let descriptionLength = try bigEndianUInt32(body, at: &offset)
		guard offset + descriptionLength <= body.count else {
			throw ParseError.malformed("truncated picture description")
		}
		let description = String(decoding: body[offset..<(offset + descriptionLength)], as: UTF8.self)
		offset += descriptionLength
		let width = try bigEndianUInt32(body, at: &offset)
		let height = try bigEndianUInt32(body, at: &offset)
		let depth = try bigEndianUInt32(body, at: &offset)
		let colors = try bigEndianUInt32(body, at: &offset)
		let imageLength = try bigEndianUInt32(body, at: &offset)
		guard offset + imageLength <= body.count else {
			throw ParseError.malformed("truncated picture image")
		}
		let image = Array(body[offset..<(offset + imageLength)])
		return FLACPicture(type: type, mime: mime, description: description, width: width, height: height, depth: depth, colors: colors, image: image)
	}

	// MARK: - Independent MP4 parsing

	private struct Atom {
		let type: [UInt8]
		let bodyStart: Int
		let bodyEnd: Int
	}

	private func fourCC(_ string: String) -> [UInt8] {
		Array(string.utf8)
	}

	/// Walks sibling atoms between `start` and `end`, handling 32/64-bit sizes and `size == 0` (extends to end).
	private func atoms(_ bytes: [UInt8], from start: Int, to end: Int) -> [Atom] {
		var result: [Atom] = []
		var offset = start
		while offset + 8 <= end {
			let size32 = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
			let type = Array(bytes[(offset + 4)..<(offset + 8)])
			var headerLength = 8
			var size = size32
			if size32 == 1 {
				guard offset + 16 <= end else { break }
				size = 0
				for index in 0..<8 {
					size = size << 8 | Int(bytes[offset + 8 + index])
				}
				headerLength = 16
			} else if size32 == 0 {
				size = end - offset
			}
			guard size >= headerLength, offset + size <= end else { break }
			result.append(Atom(type: type, bodyStart: offset + headerLength, bodyEnd: offset + size))
			offset += size
		}
		return result
	}

	/// Finds `moov > udta > meta > ilst`, descending into the container boxes by hand.
	private func ilstAtom(_ bytes: [UInt8]) -> Atom? {
		for moov in atoms(bytes, from: 0, to: bytes.count) where moov.type == fourCC("moov") {
			for udta in atoms(bytes, from: moov.bodyStart, to: moov.bodyEnd) where udta.type == fourCC("udta") {
				for meta in atoms(bytes, from: udta.bodyStart, to: udta.bodyEnd) where meta.type == fourCC("meta") {
					// `meta` is a full box: 4 bytes of version/flags before its children.
					for ilst in atoms(bytes, from: meta.bodyStart + 4, to: meta.bodyEnd) where ilst.type == fourCC("ilst") {
						return ilst
					}
				}
			}
		}
		return nil
	}

	/// Reads an ilst entry: the tag atom holds a `data` atom (4 bytes type indicator, 4 bytes locale, payload).
	private func metadataPayload(_ bytes: [UInt8], in ilst: Atom, type: [UInt8]) -> (dataType: UInt32, payload: [UInt8])? {
		guard let tag = atoms(bytes, from: ilst.bodyStart, to: ilst.bodyEnd).first(where: { $0.type == type }) else {
			return nil
		}
		guard let data = atoms(bytes, from: tag.bodyStart, to: tag.bodyEnd).first(where: { $0.type == fourCC("data") }) else {
			return nil
		}
		guard data.bodyStart + 8 <= data.bodyEnd else {
			return nil
		}
		let dataType = UInt32(bytes[data.bodyStart]) << 24 | UInt32(bytes[data.bodyStart + 1]) << 16
			| UInt32(bytes[data.bodyStart + 2]) << 8 | UInt32(bytes[data.bodyStart + 3])
		return (dataType, Array(bytes[(data.bodyStart + 8)..<data.bodyEnd]))
	}

	private func metadataString(_ bytes: [UInt8], in ilst: Atom, type: [UInt8]) -> String? {
		guard let payload = metadataPayload(bytes, in: ilst, type: type)?.payload else {
			return nil
		}
		return String(decoding: payload, as: UTF8.self)
	}

	/// Reads the UTF-8 text out of a freeform box's child (`mean`/`name`/`data`). Freeform
	/// children and `data` each carry a version/flags prefix, so callers say how many bytes to skip.
	private func freeformText(in box: Atom, type: String, skipping: Int, bytes: [UInt8]) -> String? {
		guard let child = atoms(bytes, from: box.bodyStart, to: box.bodyEnd)
			.first(where: { $0.type == fourCC(type) }) else {
			return nil
		}
		return String(decoding: Array(bytes[child.bodyStart..<child.bodyEnd].dropFirst(skipping)).drop { $0 == 0 }, as: UTF8.self)
	}

	/// The freeform `----` box whose `name` is `ISRC`, if the file has one.
	private func isrcFreeformBox(in ilst: Atom, bytes: [UInt8]) -> Atom? {
		atoms(bytes, from: ilst.bodyStart, to: ilst.bodyEnd)
			.filter { $0.type == fourCC("----") }
			.first { freeformText(in: $0, type: "name", skipping: 4, bytes: bytes) == "ISRC" }
	}

	// MARK: - Independent audio check

	/// A digest of the samples proves the audio survived the rewrite unchanged.
	private func decodedAudio(_ url: URL) throws -> (frames: AVAudioFramePosition, digest: String) {
		let file = try AVAudioFile(forReading: url)
		let format = file.processingFormat
		let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
		try file.read(into: buffer)
		var hasher = SHA256()
		if let channels = buffer.floatChannelData {
			for channel in 0..<Int(format.channelCount) {
				hasher.update(data: Data(bytes: channels[channel], count: Int(buffer.frameLength) * MemoryLayout<Float>.size))
			}
		} else if let channels = buffer.int16ChannelData {
			for channel in 0..<Int(format.channelCount) {
				hasher.update(data: Data(bytes: channels[channel], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size))
			}
		} else if let channels = buffer.int32ChannelData {
			for channel in 0..<Int(format.channelCount) {
				hasher.update(data: Data(bytes: channels[channel], count: Int(buffer.frameLength) * MemoryLayout<Int32>.size))
			}
		} else {
			throw ParseError.malformed("unsupported PCM layout")
		}
		return (buffer.frameLength == 0 ? 0 : file.length, hasher.finalize().map { String(format: "%02x", $0) }.joined())
	}

	// MARK: - FLAC

	@MainActor
	func testFLACWritesEveryTagField() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(fullTags(cover: try coverData()), to: url)

		let parsed = try parseFLAC(Data(contentsOf: url))
		let commentBlock = try XCTUnwrap(parsed.blocks.first { $0.type == 4 }, "no Vorbis comment block")
		let (vendor, rawComments) = try parseVorbisComment(commentBlock.body)
		let comments = commentsByKey(rawComments)

		XCTAssertEqual(vendor, "TidalSwift")
		XCTAssertEqual(comments["TITLE"], "Jóga (Album Version)")
		XCTAssertEqual(comments["ARTIST"], "Björk")
		XCTAssertEqual(comments["ALBUM"], "Homogénic Live")
		XCTAssertEqual(comments["ALBUMARTIST"], "ALBUM")
		XCTAssertEqual(comments["TRACKNUMBER"], "1")
		XCTAssertEqual(comments["TRACKTOTAL"], "3")
		XCTAssertEqual(comments["DISCNUMBER"], "2")
		XCTAssertEqual(comments["DISCTOTAL"], "2")
		XCTAssertEqual(comments["DATE"], "1997-09-22")
		XCTAssertEqual(comments["COPYRIGHT"], "© 1997 Björk Overseas Ltd")
		XCTAssertEqual(comments["ISRC"], "GBBKT9700061")
		XCTAssertEqual(comments["COMPILATION"], "1")
		XCTAssertEqual(comments["ITUNESADVISORY"], "1")
		// ALBUM and ALBUMARTIST are distinct keys and must survive as separate comments.
		XCTAssertEqual(rawComments.filter { $0.hasPrefix("ALBUM=") }.count, 1)
		XCTAssertEqual(rawComments.filter { $0.hasPrefix("ALBUMARTIST=") }.count, 1)
	}

	@MainActor
	func testFLACValueContainingEqualsKeepsEverythingAfterFirstEquals() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		var tags = fullTags(cover: nil)
		tags.artist = "Simon & Garfunkel = Live"
		try await FLACTagWriter.write(tags, to: url)

		let parsed = try parseFLAC(Data(contentsOf: url))
		let commentBlock = try XCTUnwrap(parsed.blocks.first { $0.type == 4 })
		let comments = commentsByKey(try parseVorbisComment(commentBlock.body).comments)
		XCTAssertEqual(comments["ARTIST"], "Simon & Garfunkel = Live")
	}

	@MainActor
	func testFLACCoverRoundTripsUnchanged() async throws {
		let cover = try coverData()
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(fullTags(cover: cover), to: url)

		let parsed = try parseFLAC(Data(contentsOf: url))
		let pictureBlock = try XCTUnwrap(parsed.blocks.first { $0.type == 6 }, "no picture block")
		let picture = try parsePicture(pictureBlock.body)

		XCTAssertEqual(picture.type, 3, "picture type must be front cover")
		XCTAssertEqual(picture.mime, "image/jpeg")
		XCTAssertEqual(picture.width, 32)
		XCTAssertEqual(picture.height, 32)
		XCTAssertEqual(picture.image, [UInt8](cover), "embedded cover bytes must be byte-identical to the source image")
	}

	@MainActor
	func testFLACKeepsStreamInfoAndAudioPayloadUntouched() async throws {
		let fixture = try fixtureURL("silent", "flac")
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		let before = try parseFLAC(Data(contentsOf: fixture))
		try await FLACTagWriter.write(fullTags(cover: try coverData()), to: url)
		let after = try parseFLAC(Data(contentsOf: url))

		// Stream info (sample rate, frame size, MD5) must not change.
		let streamInfoBefore = try XCTUnwrap(before.blocks.first { $0.type == 0 })
		let streamInfoAfter = try XCTUnwrap(after.blocks.first { $0.type == 0 })
		XCTAssertEqual(streamInfoAfter.body, streamInfoBefore.body)
		XCTAssertTrue(streamInfoAfter.body.count == 34, "stream info is 34 bytes")

		// The audio frames behind the metadata are copied verbatim.
		XCTAssertEqual(after.audio, before.audio, "audio payload changed")
		XCTAssertFalse(before.audio.isEmpty)

		// One comment, one picture, and a final padding block of 8192 bytes.
		XCTAssertEqual(after.blocks.filter { $0.type == 4 }.count, 1)
		XCTAssertEqual(after.blocks.filter { $0.type == 6 }.count, 1)
		let padding = try XCTUnwrap(after.blocks.last)
		XCTAssertEqual(padding.type, 1)
		XCTAssertTrue(padding.isLast, "the last metadata block must carry the last-block flag")
		XCTAssertEqual(padding.body.count, 8192)

		// ffmpeg's own encoder comment is replaced, not duplicated.
		let comments = try parseVorbisComment(try XCTUnwrap(after.blocks.first { $0.type == 4 }).body).comments
		XCTAssertFalse(comments.contains { $0.lowercased().hasPrefix("encoder=") }, "stale encoder comment survived: \(comments)")

		// The file grows by the new metadata, never shrinks.
		let beforeSize = try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? Int
		let afterSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
		XCTAssertTrue((afterSize ?? 0) > (beforeSize ?? 0), "expected the file to grow, \(beforeSize ?? -1) -> \(afterSize ?? -1)")

		let original = try decodedAudio(fixture)
		let tagged = try decodedAudio(url)
		XCTAssertEqual(tagged.frames, original.frames)
		XCTAssertEqual(tagged.digest, original.digest, "decoded audio differs after tagging")
	}

	@MainActor
	func testFLACWritingTwiceReplacesInsteadOfAppending() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(fullTags(cover: try coverData()), to: url)
		try await FLACTagWriter.write(fullTags(cover: try coverData()), to: url)

		let parsed = try parseFLAC(Data(contentsOf: url))
		XCTAssertEqual(parsed.blocks.filter { $0.type == 4 }.count, 1)
		XCTAssertEqual(parsed.blocks.filter { $0.type == 6 }.count, 1)
		XCTAssertEqual(parsed.blocks.filter { $0.type == 1 }.count, 1)
	}

	@MainActor
	func testFLACAbsentFieldsAreOmitted() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "flac")
		defer { removeCopy(url) }
		try await FLACTagWriter.write(emptyTags(), to: url)

		let parsed = try parseFLAC(Data(contentsOf: url))
		let comments = commentsByKey(try parseVorbisComment(try XCTUnwrap(parsed.blocks.first { $0.type == 4 }).body).comments)

		XCTAssertEqual(comments["TITLE"], "Title Only")
		XCTAssertEqual(comments["ALBUM"], "Album Only")
		XCTAssertEqual(comments["TRACKNUMBER"], "1")
		XCTAssertEqual(comments["DISCNUMBER"], "1")
		XCTAssertNil(comments["ARTIST"])
		XCTAssertNil(comments["ALBUMARTIST"])
		XCTAssertNil(comments["TRACKTOTAL"])
		XCTAssertNil(comments["DISCTOTAL"])
		XCTAssertNil(comments["DATE"])
		XCTAssertNil(comments["COPYRIGHT"])
		XCTAssertNil(comments["ISRC"])
		XCTAssertNil(comments["COMPILATION"])
		XCTAssertNil(comments["ITUNESADVISORY"])
		XCTAssertFalse(parsed.blocks.contains { $0.type == 6 }, "no cover means no picture block")
	}

	// MARK: - MP4

	private static let nam: [UInt8] = [0xA9, 0x6E, 0x61, 0x6D] // ©nam
	private static let art: [UInt8] = [0xA9, 0x41, 0x52, 0x54] // ©ART
	private static let alb: [UInt8] = [0xA9, 0x61, 0x6C, 0x62] // ©alb
	private static let day: [UInt8] = [0xA9, 0x64, 0x61, 0x79] // ©day
	private static let aART: [UInt8] = [0x61, 0x41, 0x52, 0x54] // aART
	private static let cprt: [UInt8] = [0x63, 0x70, 0x72, 0x74] // cprt
	private static let trkn: [UInt8] = [0x74, 0x72, 0x6B, 0x6E] // trkn
	private static let disk: [UInt8] = [0x64, 0x69, 0x73, 0x6B] // disk
	private static let cpil: [UInt8] = [0x63, 0x70, 0x69, 0x6C] // cpil
	private static let rtng: [UInt8] = [0x72, 0x74, 0x6E, 0x67] // rtng
	private static let covr: [UInt8] = [0x63, 0x6F, 0x76, 0x72] // covr

	@MainActor
	func testMP4WritesEveryTagField() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "m4a")
		defer { removeCopy(url) }
		try await MP4TagWriter.write(fullTags(cover: try coverData()), to: url)

		let bytes = [UInt8](try Data(contentsOf: url))
		let ilst = try XCTUnwrap(ilstAtom(bytes), "no moov > udta > meta > ilst")

		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.nam), "Jóga (Album Version)")
		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.art), "Björk")
		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.alb), "Homogénic Live")
		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.aART), "ALBUM")
		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.day), "1997-09-22")
		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.cprt), "© 1997 Björk Overseas Ltd")

		let trackNumber = try XCTUnwrap(metadataPayload(bytes, in: ilst, type: Self.trkn))
		XCTAssertEqual(trackNumber.payload, [0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00], "trkn is reserved(2) + number(2) + total(2) + reserved(2)")
		let discNumber = try XCTUnwrap(metadataPayload(bytes, in: ilst, type: Self.disk))
		XCTAssertEqual(discNumber.payload, [0x00, 0x00, 0x00, 0x02, 0x00, 0x02], "disk is reserved(2) + number(2) + total(2)")

		let compilation = try XCTUnwrap(metadataPayload(bytes, in: ilst, type: Self.cpil))
		XCTAssertEqual(compilation.payload, [0x01])
		let rating = try XCTUnwrap(metadataPayload(bytes, in: ilst, type: Self.rtng))
		XCTAssertEqual(rating.payload, [0x01])
	}

	@MainActor
	func testMP4CoverRoundTripsUnchanged() async throws {
		let cover = try coverData()
		let url = try temporaryCopy(ofFixture: "silent", extension: "m4a")
		defer { removeCopy(url) }
		try await MP4TagWriter.write(fullTags(cover: cover), to: url)

		let bytes = [UInt8](try Data(contentsOf: url))
		let ilst = try XCTUnwrap(ilstAtom(bytes))
		let coverAtom = try XCTUnwrap(metadataPayload(bytes, in: ilst, type: Self.covr))
		XCTAssertEqual(coverAtom.payload, [UInt8](cover), "embedded cover bytes must be byte-identical to the source image")
	}

	@MainActor
	func testMP4KeepsAudioUntouched() async throws {
		let fixture = try fixtureURL("silent", "m4a")
		let url = try temporaryCopy(ofFixture: "silent", extension: "m4a")
		defer { removeCopy(url) }
		try await MP4TagWriter.write(fullTags(cover: try coverData()), to: url)

		let original = try decodedAudio(fixture)
		let tagged = try decodedAudio(url)
		XCTAssertGreaterThan(original.frames, 0)
		XCTAssertEqual(tagged.frames, original.frames, "frame count changed")
		XCTAssertEqual(tagged.digest, original.digest, "decoded audio differs after tagging")

		// The rewrite only adds metadata; it must not re-encode or balloon the file.
		let beforeSize = try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? Int
		let afterSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
		XCTAssertTrue((afterSize ?? 0) >= (beforeSize ?? 0), "the tagged file must not be smaller than the source")
		XCTAssertTrue((afterSize ?? 0) < (beforeSize ?? 0) * 2, "unexpected size growth: \(beforeSize ?? -1) -> \(afterSize ?? -1)")
	}

	@MainActor
	func testMP4AbsentFieldsAreOmitted() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "m4a")
		defer { removeCopy(url) }
		try await MP4TagWriter.write(emptyTags(), to: url)

		let bytes = [UInt8](try Data(contentsOf: url))
		let ilst = try XCTUnwrap(ilstAtom(bytes))

		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.nam), "Title Only")
		XCTAssertEqual(metadataString(bytes, in: ilst, type: Self.alb), "Album Only")
		XCTAssertNil(metadataString(bytes, in: ilst, type: Self.art))
		XCTAssertNil(metadataString(bytes, in: ilst, type: Self.aART))
		XCTAssertNil(metadataString(bytes, in: ilst, type: Self.day))
		XCTAssertNil(metadataString(bytes, in: ilst, type: Self.cprt))
		XCTAssertNil(metadataPayload(bytes, in: ilst, type: Self.cpil))
		XCTAssertNil(metadataPayload(bytes, in: ilst, type: Self.rtng))
		XCTAssertNil(metadataPayload(bytes, in: ilst, type: Self.covr))
		// Track and disc numbers are always written; the absent total becomes 0.
		let trackNumber = try XCTUnwrap(metadataPayload(bytes, in: ilst, type: Self.trkn))
		XCTAssertEqual(trackNumber.payload, [0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
		let discNumber = try XCTUnwrap(metadataPayload(bytes, in: ilst, type: Self.disk))
		XCTAssertEqual(discNumber.payload, [0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
	}

	/// `AudioTags.isrc` goes in as a freeform `----` atom, because AVFoundation exposes no iTunes
	/// ISRC identifier; other players read it as `----:com.apple.iTunes:ISRC`.
	@MainActor
	func testMP4WritesISRC() async throws {
		let url = try temporaryCopy(ofFixture: "silent", extension: "m4a")
		defer { removeCopy(url) }
		try await MP4TagWriter.write(fullTags(cover: nil), to: url)

		let bytes = [UInt8](try Data(contentsOf: url))
		let ilst = try XCTUnwrap(ilstAtom(bytes))

		// AVFoundation writes its own `iTunSMPB` freeform box too, so pick the one named ISRC.
		let isrcBox = try XCTUnwrap(isrcFreeformBox(in: ilst, bytes: bytes), "no freeform atom named ISRC in ilst")
		XCTAssertEqual(freeformText(in: isrcBox, type: "mean", skipping: 4, bytes: bytes), "com.apple.iTunes")
		XCTAssertEqual(freeformText(in: isrcBox, type: "data", skipping: 8, bytes: bytes), "GBBKT9700061")
	}

	/// The faststart fixture keeps `moov` before `mdat`, so inserting the atom shifts the media
	/// data and every `stco`/`co64` chunk offset has to grow; a stale offset makes the decoder
	/// read the wrong bytes. The AVFoundation passthrough export reorders to mdat-first, so this
	/// calls `MP4FreeformAtom.insert` directly — the only way to reach `adjustChunkOffsets`.
	@MainActor
	func testMP4FreeformAtomInsertShiftsChunkOffsetsWhenMoovPrecedesMedia() throws {
		let fixture = try fixtureURL("silent-faststart", "m4a")
		let url = try temporaryCopy(ofFixture: "silent-faststart", extension: "m4a")
		defer { removeCopy(url) }

		let originalBytes = [UInt8](try Data(contentsOf: fixture))
		let originalOrder = atoms(originalBytes, from: 0, to: originalBytes.count).map { String(decoding: $0.type, as: UTF8.self) }
		let moovBefore = try XCTUnwrap(originalOrder.firstIndex(of: "moov"))
		let mdatBefore = try XCTUnwrap(originalOrder.firstIndex(of: "mdat"))
		XCTAssertLessThan(moovBefore, mdatBefore, "fixture must put moov before mdat, got \(originalOrder)")

		MP4FreeformAtom.insert("GBBKT9700061", into: url)

		let bytes = [UInt8](try Data(contentsOf: url))
		let order = atoms(bytes, from: 0, to: bytes.count).map { String(decoding: $0.type, as: UTF8.self) }
		let moovAfter = try XCTUnwrap(order.firstIndex(of: "moov"))
		let mdatAfter = try XCTUnwrap(order.firstIndex(of: "mdat"))
		// Without this the insert could have taken the no-shift branch and proved nothing.
		XCTAssertLessThan(moovAfter, mdatAfter, "tagged file must still put moov before mdat, got \(order)")

		let ilst = try XCTUnwrap(ilstAtom(bytes))
		let isrcBox = try XCTUnwrap(isrcFreeformBox(in: ilst, bytes: bytes), "no freeform atom named ISRC in ilst")
		XCTAssertEqual(freeformText(in: isrcBox, type: "mean", skipping: 4, bytes: bytes), "com.apple.iTunes")
		XCTAssertEqual(freeformText(in: isrcBox, type: "data", skipping: 8, bytes: bytes), "GBBKT9700061")

		// Decoding both files proves the media data still sits where the chunk table says it does.
		let original = try decodedAudio(fixture)
		let tagged = try decodedAudio(url)
		XCTAssertGreaterThan(original.frames, 0)
		XCTAssertEqual(tagged.frames, original.frames, "frame count changed")
		XCTAssertEqual(tagged.digest, original.digest, "decoded audio differs after tagging")

		let beforeSize = try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? Int
		let afterSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
		XCTAssertGreaterThan(afterSize ?? 0, beforeSize ?? 0, "expected the file to grow, \(beforeSize ?? -1) -> \(afterSize ?? -1)")
	}
}
