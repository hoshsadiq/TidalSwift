//
//  EmbeddedLyrics.swift
//  TidalSwiftLib
//

import Foundation
@_exported import AVFoundation
@_exported import LRCParser

/// Lyrics carried inside a stored audio file.
///
/// A downloaded track keeps its own copy, so an offline play shows lyrics with no network
/// round trip and no dependence on the caches folder, which is pruned by size. The text is
/// LRC when the provider had timings and plain words otherwise, which is what the writers
/// put in: `LYRICS` in a FLAC comment, `©lyr` in an MP4.
public nonisolated enum EmbeddedLyrics {
	/// The lyrics embedded in `url`, or `nil` when the file carries none or cannot be read.
	///
	/// Whatever the file holds is returned as-is, without the preference tag the caches
	/// carry: the file was written once and belongs to the track rather than to a session's
	/// settings.
	public static func read(at url: URL) async -> LyricsResult? {
		let text: String?
		switch url.pathExtension.lowercased() {
		case "flac":
			text = flacLyrics(at: url)
		case "m4a", "mp4":
			text = await mp4Lyrics(at: url)
		default:
			text = nil
		}
		guard let text, let content = text.nonEmpty else { return nil }
		let lines = LRCParser.parse(content)
		return LyricsResult(lines: lines, plainText: lines.isEmpty ? content : nil, source: .file)
	}

	// MARK: - FLAC

	/// Walks the metadata blocks for the Vorbis comment and reads its `LYRICS` field.
	private static func flacLyrics(at url: URL) -> String? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		guard let marker = try? handle.read(upToCount: 4), marker == Data("fLaC".utf8) else { return nil }

		var isLast = false
		while !isLast {
			guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
			isLast = header[0] & 0x80 != 0
			let length = header[1...3].reduce(0) { $0 << 8 | Int($1) }
			guard let body = try? handle.read(upToCount: length), body.count == length else { return nil }
			guard header[0] & 0x7F == 4 else { continue }
			return lyrics(fromVorbisComment: body)
		}
		return nil
	}

	/// Reads a Vorbis comment body: little-endian lengths, then `KEY=value` entries.
	private static func lyrics(fromVorbisComment body: Data) -> String? {
		var reader = LittleEndianReader(body)
		guard let vendorLength = reader.uint32(), reader.skip(Int(vendorLength)), let count = reader.uint32() else {
			return nil
		}
		for _ in 0..<count {
			guard let length = reader.uint32(), let comment = reader.bytes(Int(length)),
				  let text = String(data: comment, encoding: .utf8) else { return nil }
			guard let separator = text.firstIndex(of: "=") else { continue }
			// Vorbis comment field names are case-insensitive.
			let key = text[text.startIndex..<separator].uppercased()
			guard key == "LYRICS" || key == "UNSYNCEDLYRICS" else { continue }
			return String(text[text.index(after: separator)...])
		}
		return nil
	}

	private struct LittleEndianReader {
		private let data: Data
		private var offset = 0

		init(_ data: Data) {
			self.data = data
		}

		mutating func uint32() -> UInt32? {
			guard offset + 4 <= data.count else { return nil }
			let value = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { total, pair in
				total | UInt32(pair.element) << (8 * UInt32(pair.offset))
			}
			offset += 4
			return value
		}

		mutating func skip(_ count: Int) -> Bool {
			guard offset + count <= data.count else { return false }
			offset += count
			return true
		}

		mutating func bytes(_ count: Int) -> Data? {
			guard offset + count <= data.count else { return nil }
			defer { offset += count }
			return data[offset..<(offset + count)]
		}
	}

	// MARK: - MP4

	private static func mp4Lyrics(at url: URL) async -> String? {
		let asset = AVURLAsset(url: url)
		guard let items = try? await asset.load(.metadata) else { return nil }
		// The only lyrics identifier AVFoundation defines for an MP4; there is no common one.
		for item in items where item.identifier == .iTunesMetadataLyrics {
			guard let text = try? await item.load(.stringValue) else { continue }
			if let content = text.nonEmpty {
				return content
			}
		}
		return nil
	}
}
