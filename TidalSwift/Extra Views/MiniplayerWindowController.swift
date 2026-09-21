//
//  MiniplayerWindowController.swift
//  TidalSwift
//

import SwiftUI
import AppKit
import TidalSwiftLib

#if canImport(AppKit)
/// The floating miniplayer window.
///
/// Owns the window chrome — floating level, hidden title bar, size
/// persistence — while `MiniplayerView` owns the content and the mode toggle.
/// The window is created once in `TidalSwiftAppModel.initSecondaryWindows()`
/// and shown/hidden by the app model.
final class MiniplayerWindowController: NSWindowController, NSWindowDelegate {
	/// Called when the window closes, so the app model can un-tint its button.
	var onClose: (() -> Void)?

	convenience init(session: Session, player: Player, viewState: ViewState, appModel: TidalSwiftAppModel) {
		// Titled + fullSizeContentView keeps the native window shape (rounded
		// corners, shadow, edge resizing) while the hidden, transparent title
		// bar leaves the whole surface to the content.
		let window = NSWindow(
			contentRect: .zero,
			styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		window.isMovableByWindowBackground = true
		window.isReleasedWhenClosed = false
		// Stay above the main window, including alongside a fullscreen one.
		window.level = .floating
		window.collectionBehavior = [.fullScreenAuxiliary]

		// The content draws its own ✕ and mode toggle; the system traffic
		// lights would be a second, inconsistent set of controls.
		window.standardWindowButton(.closeButton)?.isHidden = true
		window.standardWindowButton(.miniaturizeButton)?.isHidden = true
		window.standardWindowButton(.zoomButton)?.isHidden = true

		self.init(window: window)

		// Built after `self.init` so the content's ✕ can close the window.
		let content = MiniplayerView(session: session, player: player, onClose: { [weak self] in
			self?.close()
		})
		.environmentObject(player.playbackInfo)
		.environmentObject(player.queueInfo)
		.environmentObject(viewState)
		.environmentObject(appModel)
		window.contentViewController = NSHostingController(rootView: content)

		window.setContentSize(MiniplayerSettings.windowSize)
		window.minSize = MiniplayerSettings.minSize
		window.maxSize = MiniplayerSettings.maxSize
		window.center()

		window.delegate = self
	}

	// MARK: - NSWindowDelegate

	func windowDidEndLiveResize(_ notification: Notification) {
		saveSize()
	}

	func windowWillClose(_ notification: Notification) {
		saveSize()
		onClose?()
	}

	/// Persists the content size — what `setContentSize` restores — so the
	/// round trip is symmetric.
	private func saveSize() {
		guard let size = window?.contentView?.frame.size else { return }
		MiniplayerSettings.saveWindowSize(size)
	}
}

/// Size-driven layout tiers for the miniplayer's artwork controls.
///
/// Thresholds use the shorter window edge so a wide-but-short window does not
/// claim the large layout, which needs vertical room for its bottom stack.
private enum MiniplayerSizeClass {
	case small
	case medium
	case large

	init(size: CGSize) {
		let side = min(size.width, size.height)
		if side >= 400 {
			self = .large
		} else if side >= 300 {
			self = .medium
		} else {
			self = .small
		}
	}
}

/// The miniplayer's content: artwork (default) or lyrics mode, with the
/// window's custom chrome overlaid.
///
/// T14 owns the artwork mode's responsive controls and T15 the lyrics
/// renderer; this view provides the mode switch, the chrome and the current
/// track info they build on.
struct MiniplayerView: View {
	let session: Session
	let player: Player

	@EnvironmentObject var queueInfo: QueueInfo
	@EnvironmentObject var playbackInfo: PlaybackInfo

	/// Persisted so the mode survives relaunches.
	@AppStorage(MiniplayerSettings.modeKey) private var mode: MiniplayerMode = .artwork

	/// Whether the pointer is over the window; drives the transport controls'
	/// fade-in. `onHover` on the root fires for the whole content area, so the
	/// controls stay visible while the pointer is anywhere over the window.
	@State private var isHovering = false

	/// Closes the hosting window; injected by `MiniplayerWindowController`.
	var onClose: () -> Void = {}

	var body: some View {
		ZStack {
			content
			chrome
		}
		.frame(minWidth: MiniplayerSettings.minSize.width, minHeight: MiniplayerSettings.minSize.height)
		.background(Color.black)
		.onHover { isHovering = $0 }
		// The window is always black, so pin the scheme to dark: the shared
		// lyrics renderer uses `Color.primary`, which must resolve to white here
		// regardless of the app's appearance.
		.environment(\.colorScheme, .dark)
		// The transparent full-size title bar still reserves a safe-area inset;
		// without this the bottom transport row and artist line get clipped.
		.ignoresSafeArea()
	}

	// MARK: - Content

	@ViewBuilder
	private var content: some View {
		switch mode {
		case .artwork:
			artworkMode
		case .lyrics:
			LyricsContentView(session: session, player: player, style: .miniplayer)
		}
	}

	private var artworkMode: some View {
		GeometryReader { metrics in
			let sizeClass = MiniplayerSizeClass(size: metrics.size)
			ZStack {
				artworkBackground

				// Scrim so the overlaid metadata stays readable on bright covers.
				LinearGradient(
					colors: [.black.opacity(0.1), .black.opacity(0.7)],
					startPoint: .top,
					endPoint: .bottom
				)

				overlay(for: sizeClass)
			}
			.clipped()
		}
	}

	@ViewBuilder
	private var artworkBackground: some View {
		if let url = queueInfo.currentItem?.track.getCoverUrl(session: session, resolution: 1280) {
			AsyncImage(url: url) { image in
				image.resizable().scaledToFill()
			} placeholder: {
				Color.black
			}
		} else {
			Color.black
		}
	}

	/// The responsive control layer. Small and medium keep the transport
	/// centred over the artwork (hover-gated); large switches to a bottom bar
	/// with metadata, heart, progress and the full transport.
	@ViewBuilder
	private func overlay(for sizeClass: MiniplayerSizeClass) -> some View {
		switch sizeClass {
		case .small, .medium:
			if !queueInfo.queue.isEmpty {
				centredTransport(extended: sizeClass == .medium)
			}
			VStack {
				Spacer(minLength: 0)
				trackInfo
			}
			.padding(16)
		case .large:
			largeControls
		}
	}

	/// Play/pause, previous and next (plus shuffle/repeat once the window is
	/// large enough), centred over the artwork. Hidden until the pointer enters
	/// the window; `allowsHitTesting` keeps the invisible cluster from
	/// swallowing clicks meant for the artwork.
	private func centredTransport(extended: Bool) -> some View {
		transportRow(extended: extended)
			.foregroundStyle(.white)
			.padding(.horizontal, 22)
			.padding(.vertical, 14)
			.background(Capsule().fill(Color.black.opacity(0.35)))
			.opacity(isHovering ? 1 : 0)
			.animation(.easeInOut(duration: 0.2), value: isHovering)
			.allowsHitTesting(isHovering)
	}

	/// The large layout: metadata bottom-left with the heart bottom-right, a
	/// full-width progress bar, and the transport centred underneath.
	private var largeControls: some View {
		VStack(spacing: 12) {
			Spacer(minLength: 0)
			HStack(alignment: .bottom, spacing: 12) {
				trackInfo
				if let track = queueInfo.currentItem?.track {
					FavoriteButton(track: track, session: session)
						.font(.system(size: 18))
				}
			}
			if !queueInfo.queue.isEmpty {
				ProgressBar(player: player)
				transportRow(extended: true)
					.foregroundStyle(.white)
			}
		}
		.padding(16)
	}

	private func transportRow(extended: Bool) -> some View {
		HStack(spacing: 24) {
			if extended {
				transportButton(
					symbol: "shuffle",
					size: 18,
					help: "Shuffle",
					isActive: playbackInfo.shuffle
				) {
					playbackInfo.shuffle.toggle()
				}
			}
			transportButton(symbol: "backward.fill", size: 20, help: "Previous") {
				player.previous()
			}
			transportButton(
				symbol: playbackInfo.playing ? "pause.fill" : "play.fill",
				size: 30,
				help: playbackInfo.playing ? "Pause" : "Play"
			) {
				player.togglePlay()
			}
			transportButton(symbol: "forward.fill", size: 20, help: "Next") {
				player.next()
			}
			if extended {
				transportButton(
					symbol: playbackInfo.repeatState == .single ? "repeat.1" : "repeat",
					size: 18,
					help: "Repeat",
					isActive: playbackInfo.repeatState != .off
				) {
					playbackInfo.repeatState = playbackInfo.repeatState.next()
				}
			}
		}
	}

	private func transportButton(
		symbol: String,
		size: CGFloat,
		help: String,
		isActive: Bool? = nil,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: size, weight: .semibold))
				.foregroundStyle(isActive.map { $0 ? Color.controlAccentColor : Color.white.opacity(0.6) } ?? Color.white)
				.frame(width: size + 16, height: size + 16)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help(help)
		.accessibilityLabel(help)
	}

	@ViewBuilder
	private var trackInfo: some View {
		if let track = queueInfo.currentItem?.track {
			VStack(alignment: .leading, spacing: 3) {
				Text(track.title)
					.font(.headline)
					.lineLimit(1)
				Text(track.artists.formArtistString())
					.font(.subheadline)
					.foregroundStyle(.white.opacity(0.7))
					.lineLimit(1)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.foregroundStyle(.white)
		} else {
			Text("Nothing playing")
				.font(.subheadline)
				.foregroundStyle(.white.opacity(0.7))
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	// MARK: - Chrome

	private var chrome: some View {
		VStack {
			HStack {
				chromeButton(symbol: "xmark", help: "Close") {
					onClose()
				}
				Spacer()
				chromeButton(
					symbol: mode == .lyrics ? "photo" : "quote.bubble",
					help: mode == .lyrics ? "Show artwork" : "Show lyrics"
				) {
					mode = mode == .lyrics ? .artwork : .lyrics
				}
			}
			.padding(12)
			Spacer(minLength: 0)
		}
	}

	private func chromeButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 12, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 28, height: 28)
				.background(Circle().fill(Color.black.opacity(0.35)))
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.help(help)
		.accessibilityLabel(help)
	}
}
#endif
