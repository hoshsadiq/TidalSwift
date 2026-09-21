//
//  SimilarTracksPanel.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// The "Similar tracks" panel of the Now Playing drawer.
///
/// Two sections: "Mixes & Radio" (Track Radio + Artist Radio cards) and
/// "Suggested tracks" (the track's radio as a list of rows). Data is fetched
/// when the panel opens and cached per track id, so re-opening the panel for
/// the same track is instant.
struct SimilarTracksPanel: View {
	let session: Session
	let player: Player
	let track: Track

	@State private var phase: Phase = .loading
	@State private var loadedTrackId: Int?
	@State private var mixes: [MixesItem] = []
	@State private var suggestions: [Track] = []

	private enum Phase {
		case loading
		case loaded
		case error
	}

	private var cachedEntry: SimilarTracksCache.Entry? {
		SimilarTracksCache.shared.entry(for: track.id)
	}

	var body: some View {
		Group {
			if let cached = cachedEntry {
				contentView(mixes: cached.mixes, suggestions: cached.suggestions)
			} else if phase == .error, loadedTrackId == track.id {
				errorView
			} else if phase == .loaded, loadedTrackId == track.id {
				contentView(mixes: mixes, suggestions: suggestions)
			} else {
				loadingView
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.task(id: track.id) {
			await load()
		}
	}

	// MARK: - Sections

	private func contentView(mixes: [MixesItem], suggestions: [Track]) -> some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				mixesSection(mixes)
				suggestionsSection(suggestions)
			}
			.padding(SimilarTracksPanelLayout.contentPadding)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private func mixesSection(_ mixes: [MixesItem]) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			sectionHeader("Mixes & Radio")
			if mixes.isEmpty {
				emptyText("No mixes available")
			} else {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(alignment: .top, spacing: SimilarTracksPanelLayout.cardSpacing) {
						ForEach(mixes) { mix in
							MixGridItem(
								mix: mix,
								session: session,
								player: player,
								artworkSize: SimilarTracksPanelLayout.mixCardSize,
								artworkURL: artworkURL(for: mix)
							)
						}
					}
					.padding(.vertical, 10)
					.padding(.horizontal, 4)
				}
			}
		}
	}

	/// The card artwork real TIDAL shows: the track's cover for Track Radio and
	/// the artist's picture for Artist Radio.
	private func artworkURL(for mix: MixesItem) -> URL? {
		switch mix.mixType {
		case .track:
			return track.getCoverUrl(session: session, resolution: 320)
		case .artist:
			return track.artists.first?.pictureUrl(session: session, resolution: 320)
		default:
			return nil
		}
	}

	private func suggestionsSection(_ suggestions: [Track]) -> some View {
		let suggestions = suggestions.filter { $0.id != track.id }
		return VStack(alignment: .leading, spacing: 12) {
			sectionHeader("Suggested tracks")
			if suggestions.isEmpty {
				emptyText("No suggestions")
			} else {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(suggestions) { suggestion in
						SuggestionRow(track: suggestion, session: session, player: player)
						Divider()
							.padding(.leading, 58)
					}
				}
			}
		}
	}

	private func sectionHeader(_ title: String) -> some View {
		Text(title)
			.font(.system(size: 15, weight: .semibold))
			.foregroundStyle(.primary)
	}

	private func emptyText(_ text: String) -> some View {
		Text(text)
			.font(.system(size: 13))
			.foregroundStyle(Color.primary.opacity(0.55))
			.padding(.vertical, 8)
	}

	// MARK: - Loading

	private var loadingView: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				VStack(alignment: .leading, spacing: 12) {
					sectionHeader("Mixes & Radio")
					HStack(alignment: .top, spacing: SimilarTracksPanelLayout.cardSpacing) {
						ForEach(0..<3, id: \.self) { _ in
							SkeletonMixCard(size: SimilarTracksPanelLayout.mixCardSize)
						}
						Spacer(minLength: 0)
					}
				}
				VStack(alignment: .leading, spacing: 12) {
					sectionHeader("Suggested tracks")
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(0..<5, id: \.self) { _ in
							SkeletonSuggestionRow()
							Divider()
								.padding(.leading, 58)
						}
					}
				}
			}
			.padding(SimilarTracksPanelLayout.contentPadding)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	// MARK: - Error

	private var errorView: some View {
		VStack(spacing: 10) {
			Image(systemName: "exclamationmark.triangle")
				.font(.system(size: 22))
			Text("Couldn't load similar tracks")
				.font(.system(size: 13))
			Button {
				Task {
					await load(force: true)
				}
			} label: {
				Text("Retry")
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(.primary)
					.padding(.horizontal, 16)
					.padding(.vertical, 6)
					.background(Capsule().fill(Color.primary.opacity(0.15)))
					.contentShape(Capsule())
			}
			.buttonStyle(.plain)
		}
		.foregroundStyle(Color.primary.opacity(0.7))
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: - Loading data

	private func load(force: Bool = false) async {
		if !force, let cached = SimilarTracksCache.shared.entry(for: track.id) {
			mixes = cached.mixes
			suggestions = cached.suggestions
			loadedTrackId = track.id
			phase = .loaded
			return
		}
		phase = .loading
		async let fetchedMixes = session.trackMixesRadio(trackId: track.id)
		async let fetchedSuggestions = session.trackSimilar(trackId: track.id)
		let (mixesResult, suggestionsResult) = await (fetchedMixes, fetchedSuggestions)
		// A cancelled task means the panel closed or the track changed; the
		// replacement task owns the state now.
		guard !Task.isCancelled else { return }
		guard mixesResult != nil || suggestionsResult != nil else {
			loadedTrackId = track.id
			phase = .error
			return
		}
		mixes = mixesResult ?? []
		suggestions = suggestionsResult ?? []
		if let mixesResult, let suggestionsResult {
			SimilarTracksCache.shared.store(
				SimilarTracksCache.Entry(mixes: mixesResult, suggestions: suggestionsResult),
				for: track.id
			)
		}
		loadedTrackId = track.id
		phase = .loaded
	}
}

private enum SimilarTracksPanelLayout {
	static let mixCardSize: CGFloat = 160
	static let cardSpacing: CGFloat = 16
	static let contentPadding: CGFloat = 20
}

/// Pulsing placeholder matching `MixGridItem`'s footprint.
private struct SkeletonMixCard: View {
	let size: CGFloat

	@State private var pulsing = false

	var body: some View {
		VStack(spacing: 6) {
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(Color.primary.opacity(0.12))
				.frame(width: size, height: size)
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(Color.primary.opacity(0.12))
				.frame(width: size * 0.75, height: 10)
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(Color.primary.opacity(0.12))
				.frame(width: size * 0.5, height: 8)
		}
		.padding(5)
		.opacity(pulsing ? 0.45 : 1)
		.animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
		.onAppear { pulsing = true }
	}
}

/// A single "Suggested tracks" row, matching TIDAL's list: a small album
/// thumbnail, title over artist, a trailing "+" add-to-queue button and a "⋯"
/// menu. Tapping the row plays the track.
private struct SuggestionRow: View {
	let track: Track
	let session: Session
	let player: Player

	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var playbackInfo: PlaybackInfo

	private var isPlaying: Bool {
		guard !queueInfo.queue.isEmpty, queueInfo.queue.indices.contains(queueInfo.currentIndex) else { return false }
		return queueInfo.queue[queueInfo.currentIndex].track == track
	}

	var body: some View {
		HStack(spacing: 10) {
			cover
			VStack(alignment: .leading, spacing: 2) {
				Text(track.title)
					.fontWeight(.semibold)
					.lineLimit(1)
					.truncationMode(.tail)
				Text(track.artists.formArtistString())
					.font(.subheadline)
					.foregroundColor(.secondary)
					.lineLimit(1)
					.truncationMode(.tail)
			}
			Spacer(minLength: 8)
			Button {
				player.add(track: track, .last)
			} label: {
				Image(systemName: "plus")
					.secondaryIconColor()
			}
			.buttonStyle(.plain)
			.help("Add to queue")
			.disabled(track.isUnavailable)
			Menu {
				TrackContextMenu(track: track, session: session, player: player)
			} label: {
				Image(systemName: "ellipsis")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.secondaryIconColor()
			.help("More")
		}
		.padding(.vertical, 6)
		.padding(.horizontal, 8)
		.background(
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(isPlaying ? Color.controlAccentColor.opacity(0.18) : .clear)
		)
		.contentShape(Rectangle())
		.foregroundColor(track.isUnavailable || playbackInfo.failedTrackIds.contains(track.id) ? .secondary : .primary)
		.help(toolTipString)
		.onTapGesture {
			guard !track.isUnavailable else { return }
			player.add(track: track, .now)
		}
		.contextMenu {
			TrackContextMenu(track: track, session: session, player: player)
		}
	}

	@ViewBuilder
	private var cover: some View {
		ZStack {
			if let coverUrl = track.getCoverUrl(session: session, resolution: 80) {
				ArtworkImage(url: coverUrl, size: 40, showsShadow: false)
			} else {
				Rectangle()
					.foregroundColor(.black)
			}
			if isPlaying {
				Rectangle()
					.fill(Color.black.opacity(0.45))
				Image(systemName: "play.fill")
					.foregroundColor(.white)
			}
		}
		.frame(width: 40, height: 40)
		.cornerRadius(CORNERRADIUS)
		.accessibilityHidden(true)
	}

	private var toolTipString: String {
		var s = track.title
		if let version = track.version {
			s += " (\(version))"
		}
		s += " – \(track.artists.formArtistString())"
		return s
	}
}

/// Pulsing placeholder matching `SuggestionRow`'s footprint.
private struct SkeletonSuggestionRow: View {
	@State private var pulsing = false

	var body: some View {
		HStack(spacing: 10) {
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(Color.primary.opacity(0.12))
				.frame(width: 40, height: 40)
			VStack(alignment: .leading, spacing: 6) {
				RoundedRectangle(cornerRadius: CORNERRADIUS)
					.fill(Color.primary.opacity(0.12))
					.frame(width: 160, height: 10)
				RoundedRectangle(cornerRadius: CORNERRADIUS)
					.fill(Color.primary.opacity(0.12))
					.frame(width: 100, height: 8)
			}
			Spacer(minLength: 0)
		}
		.padding(.vertical, 6)
		.padding(.horizontal, 8)
		.opacity(pulsing ? 0.45 : 1)
		.animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
		.onAppear { pulsing = true }
	}
}
