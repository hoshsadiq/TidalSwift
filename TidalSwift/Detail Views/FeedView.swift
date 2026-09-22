//
//  FeedView.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// The Feed tab: TIDAL's v2 activity feed when it has items, otherwise the
/// newest releases of the user's favourite artists.
struct FeedView: View {
	let session: Session
	let player: Player

	@EnvironmentObject var viewState: ViewState

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				Text("Feed")
					.font(.largeTitle)
					.padding(.horizontal)
				content
			}
			.padding(.vertical)
		}
	}

	@ViewBuilder
	private var content: some View {
		if let activities = viewState.cache.feedActivities, !activities.isEmpty {
			let cards = sortedActivities(activities)
			if cards.isEmpty {
				emptyState
			} else {
				activityList(cards)
			}
		} else if let releases = viewState.cache.feedReleases, !releases.isEmpty {
			releasesSection(releases)
		} else if viewState.cache.feedActivities != nil || viewState.cache.feedReleases != nil {
			emptyState
		} else if viewState.stack.last?.loadingState == .error {
			errorState
		} else {
			FullscreenLoadingSpinner()
		}
	}

	// MARK: - Activities

	private func activityList(_ activities: [FeedActivity]) -> some View {
		LazyVStack(alignment: .leading, spacing: 12) {
			ForEach(Array(activities.enumerated()), id: \.offset) { _, activity in
				activityCard(activity)
			}
		}
		.padding(.horizontal)
	}

	/// Newest first by `occurredAt`; activities without a date sort last and
	/// ties keep their server order.
	private func sortedActivities(_ activities: [FeedActivity]) -> [FeedActivity] {
		activities.enumerated()
			.filter { $0.element.isDisplayable }
			.sorted { lhs, rhs in
				let left = lhs.element.followableActivity?.occurredAt ?? .distantPast
				let right = rhs.element.followableActivity?.occurredAt ?? .distantPast
				if left != right { return left > right }
				return lhs.offset < rhs.offset
			}
			.map(\.element)
	}

	@ViewBuilder
	private func activityCard(_ activity: FeedActivity) -> some View {
		if let payload = activity.followableActivity {
			switch payload.kind {
			case .newAlbumRelease:
				if let album = payload.album {
					albumActivityCard(album: album, occurredAt: payload.occurredAt)
				}
			case .newHistoryMix:
				if let mix = payload.historyMix {
					historyMixActivityCard(mix, occurredAt: payload.occurredAt)
				}
			case .unknown:
				EmptyView()
			}
		}
	}

	private func albumActivityCard(album: Album, occurredAt: Date?) -> some View {
		activityCard(
			artworkURL: album.getCoverUrl(session: session, resolution: 320),
			title: album.title,
			subtitle: "New album by \(artistName(for: album))",
			date: occurredAt
		) {
			viewState.push(album: album)
		}
	}

	private func historyMixActivityCard(_ mix: FeedHistoryMix, occurredAt: Date?) -> some View {
		activityCard(
			artworkURL: mixArtworkURL(mix),
			title: mix.displayTitle,
			subtitle: mix.displaySubtitle,
			date: occurredAt
		) {
			viewState.push(mix: MixesItem(
				id: mix.id,
				title: mix.displayTitle,
				subTitle: mix.displaySubtitle,
				graphic: nil,
				images: mix.images,
				mixType: mix.mixType ?? .unknown
			))
		}
	}

	private func activityCard(
		artworkURL: URL?,
		title: String,
		subtitle: String,
		date: Date?,
		action: @escaping () -> Void
	) -> some View {
		HStack(spacing: 12) {
			if let artworkURL {
				ArtworkImage(url: artworkURL, size: 80)
			} else {
				RoundedRectangle(cornerRadius: CORNERRADIUS)
					.fill(Color.secondary.opacity(0.15))
					.frame(width: 80, height: 80)
			}
			VStack(alignment: .leading, spacing: 4) {
				Text(title)
					.font(.headline)
					.lineLimit(1)
				if !subtitle.isEmpty {
					Text(subtitle)
						.font(.subheadline)
						.foregroundColor(.secondary)
						.lineLimit(1)
				}
				if let date {
					Text(DateFormatter.dateOnly.string(from: date))
						.font(.caption)
						.foregroundColor(.secondary)
				}
			}
			Spacer(minLength: 0)
		}
		.padding(8)
		.background(RoundedRectangle(cornerRadius: CORNERRADIUS).fill(Color.secondary.opacity(0.1)))
		.contentShape(Rectangle())
		.onTapGesture(perform: action)
	}

	private func artistName(for album: Album) -> String {
		if let artists = album.artists {
			return artists.formArtistString()
		}
		return album.artist?.name ?? "Unknown Artist"
	}

	private func mixArtworkURL(_ mix: FeedHistoryMix) -> URL? {
		mix.images?.medium?.url
			?? mix.images?.large?.url
			?? mix.images?.small?.url
			?? mix.detailImages?.medium?.url
			?? mix.detailImages?.large?.url
			?? mix.detailImages?.small?.url
	}

	// MARK: - Fallback releases

	private func releasesSection(_ releases: [Album]) -> some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("New releases from your artists")
				.font(.title2)
				.padding(.horizontal)
			AlbumGrid(albums: releases, showArtists: true, showReleaseDate: true, session: session, player: player)
				.padding(.horizontal)
		}
	}

	// MARK: - Empty & error

	private var emptyState: some View {
		ContentUnavailableView {
			Label("Follow your favourite artists", systemImage: "bell")
		} description: {
			Text("Follow your favourite artists to get the latest updates here.")
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}

	private var errorState: some View {
		ContentUnavailableView {
			Label("Couldn't Load Feed", systemImage: "wifi.exclamationmark")
		} description: {
			Text("Check your internet connection, then try again.")
		} actions: {
			Button("Try Again") {
				viewState.feed()
			}
		}
		.frame(maxWidth: .infinity, minHeight: 300)
	}
}
