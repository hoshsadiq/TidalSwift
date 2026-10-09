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
/// report shows a dash rather than a guess. `bitDepth` is nil when the format description
/// reports 0, which is what a FLAC inside fMP4 does — that is exactly the case the tool
/// exists to surface.
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
