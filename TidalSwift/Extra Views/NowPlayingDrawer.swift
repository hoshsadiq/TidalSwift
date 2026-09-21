//
//  NowPlayingDrawer.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import AppKit
import TidalSwiftLib

/// The expanded Now Playing drawer.
///
/// Renders the top-right action cluster, the large artwork and the host region
/// for the active panel. The ambient background is layered behind this view by
/// `TopDetailView`. Panel contents are owned by later tasks; this view only
/// renders the host region and a placeholder.
struct NowPlayingDrawer: View {
	let session: Session
	let player: Player

	@EnvironmentObject var playbackInfo: PlaybackInfo
	@EnvironmentObject var queueInfo: QueueInfo

	/// The large artwork reads better with a slightly softer corner than the
	/// small cards' `CORNERRADIUS`.
	private let artworkCornerRadius: CGFloat = 8

	/// The drawer deliberately ignores the safe area (so the ambient wash reaches
	/// the top of the window), which means its content starts at the window's top
	/// edge — underneath the window toolbar that hosts `NowPlayingToolbarCluster`.
	/// This clears that toolbar so the cluster never overlaps the panel host.
	private let toolbarClearance: CGFloat = 52

	/// Fullscreen hides the toolbar, so the content only needs a little breathing
	/// room from the top edge.
	private let fullscreenTopInset: CGFloat = 28

	/// Local key monitor for Escape. Registered only while the drawer is on
	/// screen, so it cannot interfere with the rest of the app.
	@State private var escKeyMonitor: Any?

	var body: some View {
		VStack(spacing: 0) {
			GeometryReader { metrics in
				HStack(spacing: 30) {
					// Centred while idle; pushed left once a panel takes the
					// remaining width.
					if playbackInfo.activePanel == .none {
						Spacer(minLength: 0)
					}
					artwork(in: metrics.size)
					if playbackInfo.activePanel == .none {
						Spacer(minLength: 0)
					} else {
						panelHost
					}
				}
				.padding(.horizontal, 28)
				.padding(.bottom, 24)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.padding(.top, playbackInfo.isFullscreen ? fullscreenTopInset : toolbarClearance)
		// Capture taps so the covered sidebar and content stay inert.
		.contentShape(Rectangle())
		// The ambient can be light or dark, so the whole drawer renders in the
		// colour scheme that keeps its text readable on top of it.
		.environment(
			\.colorScheme,
			NowPlayingAmbient.contrastingForeground(for: playbackInfo.ambientColor) == .black ? .light : .dark
		)
		.onAppear { registerEscKeyMonitor() }
		.onDisappear { removeEscKeyMonitor() }
	}

	// MARK: - Escape handling

	/// Escape closes the active panel first, then collapses the drawer. In
	/// fullscreen the event is left untouched so macOS can exit fullscreen.
	private func registerEscKeyMonitor() {
		guard escKeyMonitor == nil else { return }
		let playbackInfo = self.playbackInfo
		escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			guard event.keyCode == 53,
				  !event.isARepeat,
				  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .capsLock]).isEmpty,
				  !playbackInfo.isFullscreen,
				  NSApp.keyWindow?.identifier?.rawValue != "com_apple_SwiftUI_Settings_window",
				  !(NSApp.keyWindow?.firstResponder is NSTextView) else {
				return event
			}
			withAnimation(.easeInOut(duration: 0.3)) {
				if playbackInfo.activePanel != .none {
					playbackInfo.activePanel = .none
				} else {
					playbackInfo.isNowPlayingExpanded = false
				}
			}
			return nil
		}
	}

	private func removeEscKeyMonitor() {
		if let escKeyMonitor {
			NSEvent.removeMonitor(escKeyMonitor)
			self.escKeyMonitor = nil
		}
	}

	// MARK: - Artwork

	@ViewBuilder
	private func artwork(in size: CGSize) -> some View {
		let side = min(size.width * 0.42, size.height * 0.92, 520)
		if let url = queueInfo.currentItem?.track.getCoverUrl(session: session, resolution: 1280) {
			ArtworkImage(url: url, size: side, cornerRadius: artworkCornerRadius)
		} else {
			RoundedRectangle(cornerRadius: artworkCornerRadius)
				.fill(Color.primary.opacity(0.08))
				.frame(width: side, height: side)
		}
	}

	// MARK: - Panel host

	private var panelHost: some View {
		RoundedRectangle(cornerRadius: artworkCornerRadius)
			.fill(Color.primary.opacity(0.06))
			.overlay { panelContent }
			.clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius))
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	@ViewBuilder
	private var panelContent: some View {
		switch playbackInfo.activePanel {
		case .credits:
			if let track = queueInfo.currentItem?.track {
				CreditsPanel(session: session, track: track)
			} else {
				panelPlaceholder(title: "Credits", symbol: "person.2", subtitle: "No credits available")
			}
		case .similar:
			if let track = queueInfo.currentItem?.track {
				SimilarTracksPanel(session: session, player: player, track: track)
			} else {
				panelPlaceholder(title: "Similar tracks", symbol: "sparkles")
			}
		case .lyrics:
			LyricsPanel(session: session, player: player)
		case .none:
			EmptyView()
		}
	}

	private func panelPlaceholder(title: String, symbol: String, subtitle: String = "Coming soon") -> some View {
		VStack(spacing: 8) {
			Image(systemName: symbol)
				.font(.system(size: 28))
			Text(title)
				.font(.headline)
			Text(subtitle)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.foregroundStyle(Color.primary.opacity(0.7))
	}
}

/// The drawer's action cluster, hosted in the window toolbar while the drawer is
/// expanded. In that state the toolbar's own items (back/forward, search and the
/// account button) are hidden, so these controls are all that remain.
struct NowPlayingToolbarCluster: View {
	@EnvironmentObject var playbackInfo: PlaybackInfo
	@EnvironmentObject var appModel: TidalSwiftAppModel

	var body: some View {
		HStack(spacing: 6) {
			panelPill("Similar tracks", panel: .similar)
			panelPill("Credits", panel: .credits)
			panelPill("Lyrics", panel: .lyrics)
			miniplayerButton
			fullscreenButton
			collapseButton
		}
		.padding(.leading, 16)
	}

	private func panelPill(_ title: String, panel: NowPlayingPanel) -> some View {
		let isActive = playbackInfo.activePanel == panel
		return Button {
			withAnimation(.easeInOut(duration: 0.3)) {
				// Clicking the active pill closes the panel and re-centres the
				// artwork.
				playbackInfo.activePanel = isActive ? .none : panel
			}
		} label: {
			Text(title)
				.font(.system(size: 13))
				.foregroundStyle(isActive ? Color.black : Color.primary)
				.padding(.horizontal, 14)
				.padding(.vertical, 6)
				.background(Capsule().fill(isActive ? Color.white : Color.clear))
				.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.help(title)
	}

	private var miniplayerButton: some View {
		Button {
			appModel.toggleMiniplayer()
		} label: {
			Image(systemName: "rectangle.on.rectangle")
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(appModel.isMiniplayerOpen ? Color.controlAccentColor : Color.primary)
				.frame(width: 30, height: 30)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(appModel.isMiniplayerOpen ? "Close Miniplayer" : "Open Miniplayer")
		.accessibilityLabel("Miniplayer")
	}

	private var fullscreenButton: some View {
		Button {
			guard let window = NSApp.keyWindow else { return }
			// Derive the target state from the window itself, so the icon and
			// the window cannot disagree even if a notification was missed.
			playbackInfo.isFullscreen = !window.styleMask.contains(.fullScreen)
			window.toggleFullScreen(nil)
		} label: {
			Image(systemName: playbackInfo.isFullscreen
				? "arrow.down.right.and.arrow.up.left"
				: "arrow.up.left.and.arrow.down.right")
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(.primary)
				.frame(width: 30, height: 30)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(playbackInfo.isFullscreen ? "Exit Fullscreen" : "Enter Fullscreen")
	}

	private var collapseButton: some View {
		Button {
			withAnimation(.easeInOut(duration: 0.3)) {
				playbackInfo.isNowPlayingExpanded = false
			}
		} label: {
			Image(systemName: "chevron.down")
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(.primary)
				.frame(width: 30, height: 30)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Collapse")
	}
}

extension ToolbarContent {
	/// Hosts this content without the system's shared glass background.
	///
	/// macOS 26 wraps every toolbar item in a Liquid Glass capsule by default.
	/// The drawer's action cluster has to sit directly on the ambient wash
	/// instead, so opt out where the API exists and keep the previous
	/// appearance on older systems.
	@ToolbarContentBuilder
	func withoutToolbarSharedBackground() -> some ToolbarContent {
		if #available(macOS 26.0, *) {
			sharedBackgroundVisibility(.hidden)
		} else {
			self
		}
	}
}
