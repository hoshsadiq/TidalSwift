//
//  ArtworkImage.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 17.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import AppKit
import SwiftUI
import os

/// A resilient replacement for the raw `AsyncImage` artwork used across the
/// app's cards.
///
/// A plain `AsyncImage` shows its placeholder forever when a load never
/// completes, which in light mode reads as a black rectangle. This view makes
/// the three states explicit and retries transient failures automatically:
///
/// - `.loading`: a neutral rounded placeholder, so a pending load reads as
///   "loading" rather than a black hole.
/// - `.loaded(NSImage)`: the artwork, rendered with the exact frame, corner
///   radius and shadow the cards used before.
/// - `.failed(String)`: the placeholder plus a tappable retry glyph.
struct ArtworkImage: View {
	let url: URL
	let size: CGFloat
	/// Height of the artwork frame. Defaults to `size` (square); landscape
	/// artwork such as the magazine cards passes a smaller value.
	var height: CGFloat?
	var cornerRadius: CGFloat = CORNERRADIUS
	/// Cards that never had a shadow (e.g. the compact track row) pass `false`
	/// so their artwork stays visually identical.
	var showsShadow: Bool = true

	@State private var phase: Phase = .loading
	/// Bumping this restarts the `.task`, which is how manual retry works.
	@State private var attempt: Int = 0

	private enum Phase {
		case loading
		case loaded(NSImage)
		case failed(String)
	}

	/// Delays between the automatic retries: 0.6 s after the first failure,
	/// 1.5 s after the second. A third failure is final.
	private static let retryDelays: [Duration] = [.milliseconds(600), .milliseconds(1500)]

	private static let logger = Logger(subsystem: "de.melgu.TidalSwift", category: "artwork")

	/// Decoded-image cache shared by every card. `AsyncImage` kept an internal
	/// decoded-image cache; this restores that behaviour so scrolling lazy
	/// stacks don't re-download and re-decode the same artwork on every
	/// appearance.
	private static let cache: NSCache<NSURL, NSImage> = {
		let cache = NSCache<NSURL, NSImage>()
		cache.countLimit = 500
		return cache
	}()

	/// The decoded image for `url` when it is already in the shared cache, so
	/// other views (e.g. the ambient background) can reuse it without a second
	/// network fetch.
	static func cachedImage(for url: URL) -> NSImage? {
		cache.object(forKey: url as NSURL)
	}

	var body: some View {
		ZStack {
			switch phase {
			case .loading:
				placeholder
			case .loaded(let image):
				Image(nsImage: image)
					.resizable()
					.scaledToFit()
			case .failed:
				placeholder
					.overlay(retryButton)
			}
		}
		.frame(width: size, height: height ?? size)
		.cornerRadius(cornerRadius)
		.shadow(radius: showsShadow ? SHADOWRADIUS : 0, y: showsShadow ? SHADOWY : 0)
		.accessibilityHidden(true)
		// Keying on the URL as well as the attempt means a view reused with a
		// different URL can't briefly show the previous image.
		.task(id: "\(url.absoluteString)#\(attempt)") {
			await load()
		}
	}

	private var placeholder: some View {
		Rectangle()
			.fill(Color.secondary.opacity(0.15))
	}

	private var retryButton: some View {
		Button {
			attempt += 1
		} label: {
			Image(systemName: "arrow.clockwise")
				.font(.system(size: max(12, size * 0.2), weight: .semibold))
				.foregroundColor(.secondary)
		}
		.buttonStyle(.plain)
		.help("Retry loading artwork")
	}

	private func load() async {
		if let cached = Self.cache.object(forKey: url as NSURL) {
			phase = .loaded(cached)
			return
		}
		phase = .loading
		for retry in 0...Self.retryDelays.count {
			do {
				let image = try await fetchImage()
				guard !Task.isCancelled else { return }
				Self.cache.setObject(image, forKey: url as NSURL)
				phase = .loaded(image)
				return
			} catch {
				guard !Task.isCancelled else { return }
				let isPermanent = (error as? ArtworkError)?.isPermanent ?? false
				if isPermanent || retry == Self.retryDelays.count {
					phase = .failed(error.localizedDescription)
					// Cheap early warning: the only runtime signal for artwork
					// that never loads. The earlier "artwork stays black" report
					// turned out to be a stale binary, so this is just a safety
					// net rather than a diagnostic for an open bug.
					Self.logger.error("artwork failed url=\(url.absoluteString, privacy: .public) error=\(String(describing: error), privacy: .public)")
					return
				}
				try? await Task.sleep(for: Self.retryDelays[retry])
				guard !Task.isCancelled else { return }
			}
		}
	}

	/// Fetches and decodes the artwork, classifying the failure so the caller
	/// can decide whether a retry is worthwhile.
	private func fetchImage() async throws -> NSImage {
		let (data, response) = try await URLSession.shared.data(from: url)
		if let http = response as? HTTPURLResponse {
			// 4xx is permanent: the same URL will keep failing, so retrying is
			// pointless. 5xx and transport errors are treated as transient.
			if (400..<500).contains(http.statusCode) {
				throw ArtworkError.clientError(http.statusCode)
			}
			guard (200..<300).contains(http.statusCode) else {
				throw ArtworkError.serverError(http.statusCode)
			}
		}
		guard let image = NSImage(data: data) else {
			throw ArtworkError.invalidImageData
		}
		return image
	}
}

private enum ArtworkError: Error {
	case invalidImageData
	case clientError(Int)
	case serverError(Int)

	/// 4xx responses are permanent; everything else is retried.
	var isPermanent: Bool {
		if case .clientError = self { return true }
		return false
	}
}
