//
//  NowPlayingAmbient.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 15.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import os
import TidalSwiftLib

#if canImport(AppKit)
import AppKit
import CoreImage
#endif

/// Derives an ambient background color from the current track's artwork for the Now Playing drawer.
enum NowPlayingAmbient {
	/// Dark neutral shown when no artwork colour can be derived (nothing playing,
	/// artwork missing, or derivation failed).
	static let fallback = Color(hue: 0, saturation: 0, brightness: 0.12)

	/// WCAG relative luminance of a colour, used to choose a readable foreground.
	static func luminance(of color: Color) -> Double {
		#if canImport(AppKit)
		let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(calibratedWhite: 0.12, alpha: 1)
		func linear(_ component: CGFloat) -> Double {
			let c = Double(component)
			return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear(nsColor.redComponent)
			+ 0.7152 * linear(nsColor.greenComponent)
			+ 0.0722 * linear(nsColor.blueComponent)
		#else
		return 0
		#endif
	}

	/// A foreground colour that stays readable on top of `background`.
	static func contrastingForeground(for background: Color) -> Color {
		luminance(of: background) > 0.5 ? .black : .white
	}

	#if canImport(AppKit)
	private static let logger = Logger(subsystem: "de.melgu.TidalSwift", category: "ambient")

	/// Derived colours keyed by artwork URL. In-memory only: switching back to a
	/// track reuses its colour instead of recomputing, which also avoids a
	/// flicker while the artwork reloads.
	private static let cache: NSCache<NSURL, NSColor> = {
		let cache = NSCache<NSURL, NSColor>()
		cache.countLimit = 100
		return cache
	}()

	/// Average color of the given artwork, tuned to the TIDAL look, or `nil` when
	/// it can't be derived.
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
		return tuned(red: CGFloat(bitmap[0]) / 255,
					 green: CGFloat(bitmap[1]) / 255,
					 blue: CGFloat(bitmap[2]) / 255)
	}

	/// The ambient colour for an artwork URL, cached per URL.
	///
	/// Reuses the decoded image from `ArtworkImage`'s shared cache when it is
	/// already loaded, so the common case costs no extra network request. The
	/// artwork URL itself already exists — nothing new is fetched from the API.
	static func color(for url: URL) async -> Color {
		if let cached = cache.object(forKey: url as NSURL) {
			return Color(nsColor: cached)
		}
		let image: NSImage
		if let cachedImage = ArtworkImage.cachedImage(for: url) {
			image = cachedImage
		} else if let (data, _) = try? await URLSession.shared.data(from: url),
				  let downloaded = NSImage(data: data) {
			image = downloaded
		} else {
			logger.error("ambient derivation failed url=\(url.absoluteString, privacy: .public)")
			return fallback
		}
		guard let color = color(from: image) else {
			logger.error("ambient derivation failed url=\(url.absoluteString, privacy: .public)")
			return fallback
		}
		cache.setObject(NSColor(color), forKey: url as NSURL)
		logger.debug("ambient color url=\(url.absoluteString, privacy: .public) color=\(String(describing: color), privacy: .public)")
		return color
	}

	/// Keeps the artwork's hue but cuts saturation and pins brightness into the
	/// ~25–35% band, so the ambient reads as a deep, muted TIDAL-style wash
	/// rather than a bright copy of the cover.
	private static func tuned(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
		let base = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
			.usingColorSpace(.deviceRGB) ?? NSColor(calibratedWhite: 0.2, alpha: 1)
		var hue: CGFloat = 0
		var saturation: CGFloat = 0
		var brightness: CGFloat = 0
		var alpha: CGFloat = 0
		base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
		let tunedSaturation = min(saturation * 0.55, 0.45)
		let tunedBrightness = min(max(0.22 + brightness * 0.13, 0.22), 0.35)
		return Color(hue: Double(hue),
					 saturation: Double(tunedSaturation),
					 brightness: Double(tunedBrightness))
	}
	#endif
}

/// Host layer for the Now Playing drawer's ambient background.
///
/// Renders the colour derived from the current track's artwork behind the
/// drawer while it is expanded. The colour is cached per artwork URL, so
/// switching tracks (or reopening the drawer) does not recompute or flicker.
struct NowPlayingAmbientLayer: View {
	let session: Session

	@EnvironmentObject var playbackInfo: PlaybackInfo
	@EnvironmentObject var queueInfo: QueueInfo

	var body: some View {
		Rectangle()
			.fill(playbackInfo.ambientColor)
			.ignoresSafeArea()
			.allowsHitTesting(false)
			// Recompute when the track changes; the URL is the cache key, so a
			// previously seen track resolves instantly. The drawer's expansion is
			// deliberately not part of the key: the layer is only mounted while
			// expanded, and re-running on collapse would reset the colour to the
			// fallback mid-transition.
			.task(id: artworkUrl?.absoluteString ?? "none") {
				await updateAmbientColor()
			}
	}

	/// The current track's large cover URL, or `nil` when nothing is playing.
	private var artworkUrl: URL? {
		queueInfo.currentItem?.track.getCoverUrl(session: session, resolution: 1280)
	}

	private func updateAmbientColor() async {
		guard let url = artworkUrl else {
			playbackInfo.ambientColor = NowPlayingAmbient.fallback
			return
		}
		playbackInfo.ambientColor = await NowPlayingAmbient.color(for: url)
	}
}
