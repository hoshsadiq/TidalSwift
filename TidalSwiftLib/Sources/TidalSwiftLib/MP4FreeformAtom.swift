//
//  MP4FreeformAtom.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 05.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

/// Adds the iTunes `----:com.apple.iTunes:ISRC` freeform atom to an MP4/M4A file.
///
/// AVFoundation exposes no identifier for the ISRC tag, so after `MP4TagWriter`'s passthrough
/// export the atom is spliced into the file by hand. All edits happen in memory and the result
/// is written once, atomically.
nonisolated enum MP4FreeformAtom {
	/// The iTunes namespace other players expect in the `mean` box of a freeform tag.
	private static let mean = "com.apple.iTunes"
	private static let name = "ISRC"

	/// Inserts or replaces the ISRC atom at `url`.
	///
	/// Never throws. A file whose box sizes or chunk offsets don't add up is left exactly as it
	/// was: a missing ISRC costs a metadata field, a corrupted file costs the download.
	static func insert(_ isrc: String, into url: URL) {
		guard !isrc.isEmpty, let original = try? Data(contentsOf: url), !original.isEmpty else {
			return
		}
		guard let updated = addingISRC(isrc, to: [UInt8](original)) else {
			return
		}
		try? Data(updated).write(to: url, options: .atomic)
	}

	// MARK: - Box model

	private struct Box {
		let type: String
		let start: Int
		let headerLength: Int
		let size: Int
		var bodyStart: Int { start + headerLength }
		var bodyEnd: Int { start + size }
	}

	private struct Insertion {
		let removed: Range<Int>
		let content: [UInt8]
		let ancestors: [Box]
	}

	/// Walks sibling boxes in `bytes[start..<end]`. `nil` means a size ran past the range, i.e.
	/// the file isn't laid out the way the format says, and we must not touch it.
	private static func boxes(in bytes: [UInt8], from start: Int, to end: Int) -> [Box]? {
		var result: [Box] = []
		var offset = start
		while offset + 8 <= end {
			let size32 = readUInt32(bytes, at: offset)
			let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
			let headerLength: Int
			let size: Int
			if size32 == 1 {
				// 64-bit size: the real size is the eight bytes following the header.
				guard offset + 16 <= end else { return nil }
				size = Int(clamping: readUInt64(bytes, at: offset + 8))
				headerLength = 16
			} else if size32 == 0 {
				// "extends to the end of the enclosing box", only used by a final box.
				size = end - offset
				headerLength = 8
			} else {
				size = Int(size32)
				headerLength = 8
			}
			guard size >= headerLength, offset + size <= end else { return nil }
			result.append(Box(type: type, start: offset, headerLength: headerLength, size: size))
			offset += size
		}
		// Leftover bytes that can't hold a box header mean the walk lost alignment.
		return offset == end ? result : nil
	}

	private static func isISRC(_ box: Box, in bytes: [UInt8]) -> Bool {
		guard box.type == "----" else { return false }
		// mean/name carry four version/flags bytes before their UTF-8 text.
		guard let children = boxes(in: bytes, from: box.bodyStart, to: box.bodyEnd),
			  let nameBox = children.first(where: { $0.type == "name" }),
			  nameBox.bodyStart + 4 <= nameBox.bodyEnd else {
			return false
		}
		let text = String(decoding: bytes[(nameBox.bodyStart + 4)..<nameBox.bodyEnd].drop { $0 == 0 }, as: UTF8.self)
		return text == name
	}

	// MARK: - Locating the insertion point

	private static func addingISRC(_ isrc: String, to bytes: [UInt8]) -> [UInt8]? {
		guard let top = boxes(in: bytes, from: 0, to: bytes.count),
			  let moov = top.first(where: { $0.type == "moov" }) else {
			return nil
		}
		// Chunk offsets are absolute file positions. When moov precedes mdat, growing moov pushes
		// the media data, so every stco/co64 entry has to grow by the same amount. If moov follows
		// mdat, nothing before the media moved and no fix-up is needed.
		let shiftsMedia = top.contains { $0.type == "mdat" && $0.start > moov.start }

		guard let moovChildren = boxes(in: bytes, from: moov.bodyStart, to: moov.bodyEnd) else {
			return nil
		}
		guard let insertion = insertion(in: moovChildren, moov: moov, isrc: isrc, bytes: bytes) else {
			return nil
		}
		return applying(bytes: bytes, insertion: insertion, shiftsMedia: shiftsMedia)
	}

	/// Finds moov > udta > meta > ilst and returns where the freeform box goes, creating whichever
	/// of the three containers is missing.
	private static func insertion(in moovChildren: [Box], moov: Box, isrc: String, bytes: [UInt8]) -> Insertion? {
		guard let udta = moovChildren.first(where: { $0.type == "udta" }) else {
			let ilst = box("ilst", body: freeformBox(isrc))
			let meta = box("meta", body: ilst, versionFlags: true)
			let newUdta = box("udta", body: meta)
			return Insertion(removed: moov.bodyEnd..<moov.bodyEnd, content: newUdta, ancestors: [moov])
		}
		guard let udtaChildren = boxes(in: bytes, from: udta.bodyStart, to: udta.bodyEnd) else {
			return nil
		}
		guard let meta = udtaChildren.first(where: { $0.type == "meta" }) else {
			let ilst = box("ilst", body: freeformBox(isrc))
			let newMeta = box("meta", body: ilst, versionFlags: true)
			return Insertion(removed: udta.bodyEnd..<udta.bodyEnd, content: newMeta, ancestors: [moov, udta])
		}
		// meta is a full box: four version/flags bytes sit before its children.
		guard let metaChildren = boxes(in: bytes, from: meta.bodyStart + 4, to: meta.bodyEnd) else {
			return nil
		}
		guard let ilst = metaChildren.first(where: { $0.type == "ilst" }) else {
			let newIlst = box("ilst", body: freeformBox(isrc))
			return Insertion(removed: meta.bodyEnd..<meta.bodyEnd, content: newIlst, ancestors: [moov, udta, meta])
		}

		let ancestors = [moov, udta, meta, ilst]
		let replacement = freeformBox(isrc)
		guard let ilstChildren = boxes(in: bytes, from: ilst.bodyStart, to: ilst.bodyEnd) else {
			return nil
		}
		// Replace in place rather than appending, so repeated tagging doesn't pile up atoms.
		if let existing = ilstChildren.first(where: { isISRC($0, in: bytes) }) {
			return Insertion(removed: existing.start..<existing.bodyEnd, content: replacement, ancestors: ancestors)
		}
		return Insertion(removed: ilst.bodyEnd..<ilst.bodyEnd, content: replacement, ancestors: ancestors)
	}

	// MARK: - Applying the edit

	private static func applying(bytes: [UInt8], insertion: Insertion, shiftsMedia: Bool) -> [UInt8]? {
		let delta = insertion.content.count - insertion.removed.count
		var result = bytes
		result.replaceSubrange(insertion.removed, with: insertion.content)
		// Ancestors all begin before the insertion point, so their size fields stay in place.
		for ancestor in insertion.ancestors {
			let newSize = ancestor.size + delta
			guard newSize >= ancestor.headerLength, writeSize(newSize, for: ancestor, into: &result) else {
				return nil
			}
		}
		if shiftsMedia {
			guard adjustChunkOffsets(in: &result, by: delta) else {
				return nil
			}
		}
		return result
	}

	private static func writeSize(_ size: Int, for box: Box, into bytes: inout [UInt8]) -> Bool {
		if box.headerLength == 16 {
			writeUInt64(UInt64(size), at: box.start + 8, into: &bytes)
		} else {
			guard size <= Int(UInt32.max) else { return false }
			writeUInt32(UInt32(size), at: box.start, into: &bytes)
		}
		return true
	}

	/// Rewrites every chunk offset inside moov by `delta`. Called only when moov precedes mdat.
	private static func adjustChunkOffsets(in bytes: inout [UInt8], by delta: Int) -> Bool {
		guard let top = boxes(in: bytes, from: 0, to: bytes.count),
			  let moov = top.first(where: { $0.type == "moov" }),
			  let moovChildren = boxes(in: bytes, from: moov.bodyStart, to: moov.bodyEnd) else {
			return false
		}
		for trak in moovChildren where trak.type == "trak" {
			guard let trakChildren = boxes(in: bytes, from: trak.bodyStart, to: trak.bodyEnd) else { return false }
			for mdia in trakChildren where mdia.type == "mdia" {
				guard let mdiaChildren = boxes(in: bytes, from: mdia.bodyStart, to: mdia.bodyEnd) else { return false }
				for minf in mdiaChildren where minf.type == "minf" {
					guard let minfChildren = boxes(in: bytes, from: minf.bodyStart, to: minf.bodyEnd) else { return false }
					for stbl in minfChildren where stbl.type == "stbl" {
						guard let stblChildren = boxes(in: bytes, from: stbl.bodyStart, to: stbl.bodyEnd) else { return false }
						for table in stblChildren where table.type == "stco" || table.type == "co64" {
							guard shiftChunkTable(table, in: &bytes, by: delta) else { return false }
						}
					}
				}
			}
		}
		return true
	}

	private static func shiftChunkTable(_ table: Box, in bytes: inout [UInt8], by delta: Int) -> Bool {
		// Full box: four version/flags bytes, then a big-endian entry count.
		let countOffset = table.bodyStart + 4
		guard countOffset + 4 <= table.bodyEnd else { return false }
		let count = Int(readUInt32(bytes, at: countOffset))
		let entryLength = table.type == "co64" ? 8 : 4
		let entriesStart = countOffset + 4
		guard entriesStart + count * entryLength <= table.bodyEnd else { return false }
		for index in 0..<count {
			let offset = entriesStart + index * entryLength
			if entryLength == 8 {
				let shifted = Int64(clamping: readUInt64(bytes, at: offset)) + Int64(delta)
				guard shifted >= 0 else { return false }
				writeUInt64(UInt64(shifted), at: offset, into: &bytes)
			} else {
				// A 32-bit offset that no longer fits needs a co64 rewrite; not worth risking a file for.
				let shifted = Int(readUInt32(bytes, at: offset)) + delta
				guard shifted >= 0, shifted <= Int(UInt32.max) else { return false }
				writeUInt32(UInt32(shifted), at: offset, into: &bytes)
			}
		}
		return true
	}

	// MARK: - Building boxes

	/// A `----` freeform box holding mean, name and the UTF-8 value.
	private static func freeformBox(_ isrc: String) -> [UInt8] {
		let meanBox = box("mean", body: versionFlags + Array(mean.utf8))
		let nameBox = box("name", body: versionFlags + Array(name.utf8))
		// The data box type is 1 (UTF-8) and the locale is 0.
		let dataBox = box("data", body: readUInt32Bytes(1) + versionFlags + Array(isrc.utf8))
		return box("----", body: meanBox + nameBox + dataBox)
	}

	private static let versionFlags: [UInt8] = [0, 0, 0, 0]

	/// Wraps `body` in an 8-byte big-endian box header. `versionFlags` inserts the four
	/// version/flags bytes that full boxes (`meta`) carry before their children.
	private static func box(_ type: String, body: [UInt8], versionFlags: Bool = false) -> [UInt8] {
		var content = versionFlags ? Self.versionFlags : []
		content.append(contentsOf: body)
		return readUInt32Bytes(UInt32(content.count + 8)) + Array(type.utf8) + content
	}

	// MARK: - Byte helpers

	private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
		UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
	}

	private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
		var value: UInt64 = 0
		for index in 0..<8 {
			value = value << 8 | UInt64(bytes[offset + index])
		}
		return value
	}

	private static func readUInt32Bytes(_ value: UInt32) -> [UInt8] {
		[UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
	}

	private static func writeUInt32(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
		for (index, byte) in readUInt32Bytes(value).enumerated() {
			bytes[offset + index] = byte
		}
	}

	private static func writeUInt64(_ value: UInt64, at offset: Int, into bytes: inout [UInt8]) {
		for index in 0..<8 {
			bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((7 - index) * 8))
		}
	}
}
