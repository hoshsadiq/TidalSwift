//
//  QueueView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 05.09.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import AppKit
import TidalSwiftLib

struct QueueView: View {
	unowned let session: Session
	unowned let player: Player

	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var appModel: TidalSwiftAppModel

	/// How long auto-follow stays paused after the last manual scroll.
	private static let autoScrollResumeDelay: TimeInterval = 10 * 60

	/// True while auto-follow is paused because the user scrolled manually.
	@State private var isUserScrolling = false
	/// When the user last scrolled manually; nil until the first manual scroll.
	@State private var lastUserScrollTime: Date?
	/// Pending idle timer that re-enables auto-follow.
	@State private var resumeAutoScrollTask: Task<Void, Never>?

	/// Queue items after the currently playing one. Items before the current index
	/// are represented by the History section instead.
	private var nextUp: [WrappedTrack] {
		guard queueInfo.queue.indices.contains(queueInfo.currentIndex) else { return [] }
		let start = queueInfo.currentIndex + 1
		guard start < queueInfo.queue.count else { return [] }
		return Array(queueInfo.queue[start...])
	}

	/// Queue items before the currently playing one, i.e. the tracks that have
	/// already played in this queue. Derived from the queue itself so it stays
	/// in sync; `queueInfo.history` is separate play-tracking bookkeeping.
	private var historyItems: [WrappedTrack] {
		guard queueInfo.queue.indices.contains(queueInfo.currentIndex) else { return [] }
		return Array(queueInfo.queue[..<queueInfo.currentIndex])
	}

	private var isEmpty: Bool {
		queueInfo.queue.isEmpty
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						if isEmpty {
							Text("Empty Queue")
								.foregroundColor(.secondary)
								.padding(.horizontal, 12)
								.padding(.vertical, 16)
						} else {
							historySection
							playingFromSection
							nextUpSection
						}
					}
					.padding(.vertical, 8)
					// Inside the document hierarchy so it can find the enclosing
					// NSScrollView and distinguish manual from programmatic scrolling.
					.background(
						QueueScrollObserver { userDidScroll(proxy: proxy) }
							.allowsHitTesting(false)
					)
				}
				.onChange(of: queueInfo.currentIndex, initial: true) { _, _ in
					scrollToCurrent(proxy: proxy)
				}
			}
		}
		.onDisappear {
			resumeAutoScrollTask?.cancel()
			resumeAutoScrollTask = nil
		}
	}

	// MARK: - Auto-scroll

	/// Auto-follow stays active until the user scrolls, then re-arms once the
	/// idle window has elapsed since that scroll.
	private var shouldAutoScroll: Bool {
		guard isUserScrolling, let lastUserScrollTime else { return true }
		return Date().timeIntervalSince(lastUserScrollTime) >= Self.autoScrollResumeDelay
	}

	/// Scrolls the queue so the currently playing row is visible. No-ops while
	/// auto-follow is paused by a manual scroll.
	private func scrollToCurrent(proxy: ScrollViewProxy) {
		guard queueInfo.currentItem != nil, shouldAutoScroll else { return }
		isUserScrolling = false
		let target = queueInfo.currentIndex
		// Deferred so the lazy stack has laid out its rows before scrolling,
		// which also covers the panel's first appearance.
		DispatchQueue.main.async {
			withAnimation(.easeInOut(duration: 0.25)) {
				proxy.scrollTo(target, anchor: .center)
			}
		}
	}

	/// Pauses auto-follow and restarts the idle timer that resumes it.
	private func userDidScroll(proxy: ScrollViewProxy) {
		lastUserScrollTime = Date()
		isUserScrolling = true
		resumeAutoScrollTask?.cancel()
		resumeAutoScrollTask = Task {
			try? await Task.sleep(for: .seconds(Self.autoScrollResumeDelay))
			guard !Task.isCancelled else { return }
			scrollToCurrent(proxy: proxy)
		}
	}

	// MARK: - Header

	private var header: some View {
		HStack {
			Text("Play queue")
				.font(.headline)
			Spacer(minLength: 8)
			Button {
				appModel.showQueuePanel = false
			} label: {
				Image(systemName: "xmark")
					.font(.system(size: 12, weight: .semibold))
					.foregroundColor(.secondary)
			}
			.buttonStyle(.plain)
			.help("Close queue")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
	}

	// MARK: - Sections

	@ViewBuilder
	private var historySection: some View {
		if !historyItems.isEmpty {
			sectionHeader("History")
			// Row identity must come from the ForEach alone. Adding an explicit
			// `.id()` makes SwiftUI reuse the row without re-evaluating it, which
			// leaves stale rows behind in the LazyVStack after queue changes.
			ForEach(historyItems) { item in
				QueueRow(item: item, session: session, player: player, isCurrent: false, queueIndex: item.id,
						 onPlay: { player.play(atIndex: item.id) })
			}
		}
	}

	@ViewBuilder
	private var playingFromSection: some View {
		if let source = queueInfo.source {
			HStack(spacing: 6) {
				Text("Playing from: \(source.title)")
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
					.help("Playing from: \(source.title)")
				Spacer(minLength: 8)
				Button("Clear") {
					player.clearQueue(leavingCurrent: true)
				}
				.buttonStyle(.plain)
				.font(.caption)
				.help("Clear queue")
			}
			.padding(.horizontal, 12)
			.padding(.top, 12)
			.padding(.bottom, 4)
		}
		if let current = queueInfo.currentItem {
			// The ForEach supplies the scroll target identity (its queue index)
			// without an explicit `.id()` on the row.
			ForEach([current]) { item in
				QueueRow(item: item, session: session, player: player, isCurrent: true, queueIndex: nil,
						 onPlay: { player.play(atIndex: queueInfo.currentIndex) })
			}
		}
	}

	@ViewBuilder
	private var nextUpSection: some View {
		if !nextUp.isEmpty {
			HStack {
				Text(nextUpLabel)
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
					.help(nextUpLabel)
				Spacer(minLength: 8)
			}
			.padding(.horizontal, 12)
			.padding(.top, 12)
			.padding(.bottom, 4)
			ForEach(nextUp) { item in
				QueueRow(item: item, session: session, player: player, isCurrent: false, queueIndex: item.id,
						 onPlay: { player.play(atIndex: item.id) })
			}
		}
	}

	private var nextUpLabel: String {
		if let source = queueInfo.source {
			return "Next Up from: \(source.title)"
		}
		return "Next Up"
	}

	private func sectionHeader(_ title: String) -> some View {
		Text(title)
			.font(.caption)
			.fontWeight(.semibold)
			.foregroundColor(.secondary)
			.textCase(.uppercase)
			.padding(.horizontal, 12)
			.padding(.top, 12)
			.padding(.bottom, 4)
	}
}

/// A single queue row: 40pt artwork thumbnail, title + artist, and optional
/// trailing remove control. `queueIndex` is the row's index in `queueInfo.queue`
/// and is nil only for the currently playing row.
private struct QueueRow: View {
	let item: WrappedTrack
	let session: Session
	let player: Player
	let isCurrent: Bool
	let queueIndex: Int?
	let onPlay: () -> Void

	var body: some View {
		HStack(spacing: 8) {
			artwork
			VStack(alignment: .leading, spacing: 2) {
				Text(item.track.title)
					.foregroundColor(.primary)
					.lineLimit(1)
					.help(trackToolTipString)
				Text(item.track.artists.formArtistString())
					.font(.caption)
					.foregroundColor(.secondary)
					.lineLimit(1)
			}
			Spacer(minLength: 4)
			if let queueIndex {
				Button {
					player.removeTrack(atIndex: queueIndex)
				} label: {
					Image(systemName: "xmark")
						.secondaryIconColor()
				}
				.buttonStyle(.plain)
				.help("Remove from queue")
			}
		}
		.padding(.vertical, 4)
		.padding(.horizontal, 8)
		.background(
			RoundedRectangle(cornerRadius: CORNERRADIUS)
				.fill(isCurrent ? Color.controlAccentColor.opacity(0.18) : .clear)
		)
		.padding(.horizontal, 4)
		.contentShape(Rectangle())
		.onTapGesture {
			onPlay()
		}
		.contextMenu {
			TrackContextMenu(track: item.track, session: session, player: player)
		}
	}

	@ViewBuilder
	private var artwork: some View {
		if let coverUrl = item.track.getCoverUrl(session: session, resolution: 80) {
			AsyncImage(url: coverUrl) { image in
				image.resizable().scaledToFit()
			} placeholder: {
				Rectangle()
			}
			.frame(width: 40, height: 40)
			.cornerRadius(CORNERRADIUS)
			.accessibilityHidden(true)
		} else {
			Rectangle()
				.foregroundColor(.black)
				.frame(width: 40, height: 40)
				.cornerRadius(CORNERRADIUS)
				.accessibilityHidden(true)
		}
	}

	private var trackToolTipString: String {
		var s = item.track.title
		if let version = item.track.version {
			s += " (\(version))"
		}
		s += " – \(item.track.artists.formArtistString())"
		return s
	}
}

struct QueuePanel: View {
	unowned let session: Session
	unowned let player: Player

	@EnvironmentObject var playbackInfo: PlaybackInfo
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		QueueView(session: session, player: player)
			.frame(width: 300)
			// While the drawer is expanded the panel adopts the drawer's ambient
			// colour so the two read as one surface; collapsed, it stays
			// translucent over whatever is behind it.
			.background {
				if playbackInfo.isNowPlayingExpanded {
					playbackInfo.ambientColor
				} else {
					Rectangle().fill(.regularMaterial)
				}
			}
			// The ambient wash can be light or dark, so render the queue in the
			// colour scheme that keeps its text readable on top of it.
			.environment(\.colorScheme, queueColorScheme)
	}

	/// Matches the drawer's own scheme so the queue text contrasts with the
	/// ambient colour behind it.
	private var queueColorScheme: ColorScheme {
		guard playbackInfo.isNowPlayingExpanded else { return colorScheme }
		return NowPlayingAmbient.contrastingForeground(for: playbackInfo.ambientColor) == .black ? .light : .dark
	}
}

/// Reports manual scrolling in the queue's enclosing `NSScrollView`.
///
/// `NSScrollView.willStartLiveScrollNotification` is posted only for
/// user-driven scrolling (trackpad or mouse wheel) and never for programmatic
/// `ScrollViewReader.scrollTo`, which is what separates the two here.
private struct QueueScrollObserver: NSViewRepresentable {
	let onUserScroll: () -> Void

	func makeNSView(context: Context) -> NSView {
		let view = ObserverView()
		view.onUserScroll = onUserScroll
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		(nsView as? ObserverView)?.onUserScroll = onUserScroll
	}

	private final class ObserverView: NSView {
		var onUserScroll: (() -> Void)?
		/// Only touched on the main thread; `nonisolated(unsafe)` lets the
		/// nonisolated `deinit` remove the registration.
		nonisolated(unsafe) private var observer: NSObjectProtocol?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard window != nil else { return }
			attachIfNeeded()
			if observer == nil {
				DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() }
			}
		}

		private func attachIfNeeded() {
			guard observer == nil, let scrollView = enclosingScrollView else { return }
			observer = NotificationCenter.default.addObserver(
				forName: NSScrollView.willStartLiveScrollNotification,
				object: scrollView,
				queue: .main
			) { [weak self] _ in
				self?.onUserScroll?()
			}
		}

		/// Never intercept clicks meant for the queue rows underneath.
		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		deinit {
			if let observer {
				NotificationCenter.default.removeObserver(observer)
			}
		}
	}
}
