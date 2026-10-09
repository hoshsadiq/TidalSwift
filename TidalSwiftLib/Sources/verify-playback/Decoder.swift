//
//  Decoder.swift
//  verify-playback
//
//  Reads the audio format out of a resolved file with AVFoundation, without playing it.
//

import AVFoundation
import CoreMedia
import Foundation

/// What a resolved file's bytes really hold, as far as AVFoundation can see them.
///
/// Every field is optional because a file AVFoundation cannot read yields nothing; the
/// report shows a dash rather than a guess. The format description reports a bit depth of 0
/// for a FLAC inside fMP4, so a FLAC's depth is read from its own STREAMINFO instead; the
/// field stays nil only when neither source names one.
struct DecodedFacts {
	var codec: String?
	var bitDepth: Int?
	var sampleRate: Int?
	var channels: Int?
	var duration: Double?
	var sizeBytes: Int = 0

	/// The whole file's average bitrate, from its size and duration. This is measured from
	/// the bytes, not a nominal figure the container claims.
	var bitrateKbps: Int? {
		guard let duration, duration > 0, sizeBytes > 0 else { return nil }
		return Int((Double(sizeBytes) * 8 / duration / 1000).rounded())
	}
}

enum AudioDecoder {
	/// Loads the file's audio tracks with `AVURLAsset`. No `AVPlayer` is created, so nothing
	/// plays and no sound is produced; the file is only read.
	static func decode(_ url: URL) async -> DecodedFacts {
		let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
		let asset = AVURLAsset(url: url)

		var duration: Double?
		if let loaded = try? await asset.load(.duration) {
			let seconds = CMTimeGetSeconds(loaded)
			if seconds.isFinite, seconds > 0 { duration = seconds }
		}

		guard let audio = (try? await asset.loadTracks(withMediaType: .audio))?.first else {
			return DecodedFacts(duration: duration, sizeBytes: size)
		}

		var description: CMFormatDescription?
		if let descriptions = try? await audio.load(.formatDescriptions) {
			description = descriptions.first
		}

		let codec = description.flatMap(codec(of:))
		var bitDepth: Int?
		var sampleRate: Int?
		var channels: Int?
		if let description, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
			if asbd.mBitsPerChannel > 0 { bitDepth = Int(asbd.mBitsPerChannel) }
			if asbd.mSampleRate > 0 { sampleRate = Int(asbd.mSampleRate) }
			if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
		}
		// A FLAC inside fMP4 reports no bit depth through AVFoundation, but the file's own
		// STREAMINFO records one. Read it from the bytes, so a 16-bit stream served for a 24-bit
		// rung is caught instead of trusted (the silent hi-res downgrade this tool exists for).
		if bitDepth == nil, codec == "flac" {
			bitDepth = FLACBitDepth.head(of: url)
		}
		return DecodedFacts(
			codec: codec,
			bitDepth: bitDepth,
			sampleRate: sampleRate,
			channels: channels,
			duration: duration,
			sizeBytes: size
		)
	}

	/// The format description's media subtype as its four-character codec name (e.g. `flac`,
	/// `aac `, `ec-3`).
	private static func codec(of description: CMFormatDescription) -> String? {
		var subtype = CMFormatDescriptionGetMediaSubType(description).bigEndian
		let text = String(bytes: withUnsafeBytes(of: &subtype) { Data($0) }, encoding: .ascii)
		return text?.trimmingCharacters(in: .whitespaces)
	}
}

/// The bit depth a FLAC file records in its STREAMINFO, read straight from the bytes.
///
/// Two layouts carry a FLAC STREAMINFO: the `dfLa` box of an fMP4 FLAC (the bytes the HLS path
/// assembles), and the native `fLaC` stream. Both put a metadata block header (one byte of
/// last-block flag and block type, then a 24-bit length) in front of the 34-byte payload; the
/// depth is five bits at bit offset 103 of that payload. `nil` when neither layout is present,
/// so the report says the depth is unverified rather than guessing it.
private enum FLACBitDepth {
	/// The head of the file is enough: an fMP4 keeps its `moov`, and with it the `dfLa` box, at
	/// the start, so the read is bounded rather than pulling a whole track into memory.
	static func head(of url: URL) -> Int? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		let data = (try? handle.read(upToCount: 1_000_000)) ?? Data()
		if let box = data.range(of: Data("dfLa".utf8)) {
			// A full box: four version/flag bytes before the first metadata block.
			return depth(in: data, metadataHeaderAt: box.upperBound + 4)
		}
		if data.starts(with: Data("fLaC".utf8)) {
			return depth(in: data, metadataHeaderAt: 4)
		}
		return nil
	}

	/// Walks the first metadata block (STREAMINFO) and reads its depth.
	private static func depth(in data: Data, metadataHeaderAt header: Int) -> Int? {
		guard header + 4 <= data.count, data[header] & 0x7F == 0 else { return nil }
		let length = Int(data[header + 1]) << 16 | Int(data[header + 2]) << 8 | Int(data[header + 3])
		let payload = header + 4
		// A STREAMINFO block is always 34 bytes; any other length means this is not one, so the
		// bytes the report leans on are a real STREAMINFO rather than four letters inside audio.
		guard length == 34, payload + 14 <= data.count else { return nil }
		// Bits 103 to 107 of the payload: the low bit of byte 12 and the high nibble of byte 13.
		let value = (Int(data[payload + 12]) & 0x01) << 4 | Int(data[payload + 13]) >> 4
		return value + 1
	}
}
