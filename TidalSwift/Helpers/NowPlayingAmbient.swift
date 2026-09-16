//
//  NowPlayingAmbient.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 15.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI

#if canImport(AppKit)
import AppKit
import CoreImage
#endif

/// Derives an ambient background color from the current track's artwork for the Now Playing drawer.
enum NowPlayingAmbient {
	// Disabled until the Now Playing drawer is built.
	/*
	#if canImport(AppKit)
	/// Average color of the given artwork, or `nil` when it can't be derived.
	static func color(from image: NSImage) -> Color? {
		guard let tiff = image.tiffRepresentation,
			  let ciImage = CIImage(data: tiff) else { return nil }
		let extent = ciImage.extent
		guard let filter = CIFilter(name: "CIAreaAverage",
									parameters: [kCIInputImageKey: ciImage,
												 kCIInputExtentKey: CIVector(cgRect: extent)]),
			  let output = filter.outputImage else { return nil }
		var bitmap = [UInt8](repeating: 0, count: 4)
		let context = CIContext(options: [.workingColorSpace: NSNull()])
		context.render(output,
					   toBitmap: &bitmap,
					   rowBytes: 4,
					   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
					   format: .RGBA8,
					   colorSpace: nil)
		return Color(red: Double(bitmap[0]) / 255,
					 green: Double(bitmap[1]) / 255,
					 blue: Double(bitmap[2]) / 255)
	}
	#endif
	*/
}

/// Host layer for the Now Playing drawer's ambient background.
///
/// Intentionally inert: it renders nothing today. When expanded, the ambient
/// color derived from the current track's artwork would be rendered here behind
/// the drawer.
struct NowPlayingAmbientLayer: View {
	@EnvironmentObject var playbackInfo: PlaybackInfo

	var body: some View {
		Group {
			if playbackInfo.isNowPlayingExpanded {
				// Replace with the artwork-derived ambient color when implemented.
				Color.clear
			}
		}
		.allowsHitTesting(false)
	}
}
