//
//  LyricsContentView.swift
//  TidalSwift
//

import SwiftUI
import TidalSwiftLib

/// The shared lyrics renderer used by both the Now Playing drawer's Lyrics
/// panel and the miniplayer's lyrics mode.
///
/// Resolves the current queue item through `LyricsResolver` and renders the
/// result in one of four states:
///
/// - `.loading`: eight skeleton lines while the resolver works.
/// - `.loaded`: timed LRC lines with the current one highlighted and scrolled to
///   the vertical centre, or a plain-text block when the winning source had no LRC.
/// - `.empty`: "No lyrics available" when no provider has lyrics for the track.
/// - `.failed`: a provider request failed, or there is no current track.
///
/// Both terminal states carry a retry button. The resolver tells a dropped
/// request from a track that has no lyrics, so an empty panel never claims the
/// wrong one.
struct LyricsContentView: View {
	/// Sizing knobs so the drawer and the (much smaller) miniplayer can share
	/// one renderer without duplicating the fetch/highlight/scroll logic.
	struct Style {
		var horizontalPadding: CGFloat
		var lineSpacing: CGFloat
		var currentFontSize: CGFloat
		var otherFontSize: CGFloat
		var showsAttribution: Bool
		/// Subtracted from half the viewport when computing the scroll slack, so
		/// the first and last lines can still reach the centre.
		var verticalSlackInset: CGFloat
		/// Whether tapping a line seeks playback to its timestamp. Off in the
		/// miniplayer, whose window is draggable by its background.
		var allowsSeeking: Bool

		static let drawer = Style(
			horizontalPadding: 24,
			lineSpacing: 26,
			currentFontSize: 32,
			otherFontSize: 27,
			showsAttribution: true,
			verticalSlackInset: 24,
			allowsSeeking: true
		)

		static let miniplayer = Style(
			horizontalPadding: 16,
			lineSpacing: 14,
			currentFontSize: 16,
			otherFontSize: 14,
			showsAttribution: true,
			verticalSlackInset: 16,
			allowsSeeking: false
		)
	}

	let session: Session
	let player: Player
	var style: Style = .drawer
	/// Whether the surface hosting this view is on screen. The miniplayer's window is
	/// retained when closed, so its content is never torn down and `.task` would keep a
	/// pending retry running; folding this into the fetch key cancels it on close instead.
	var isVisible: Bool = true

	@Environment(PlaybackInfo.self) private var playbackInfo
	@Environment(QueueInfo.self) private var queueInfo

	/// Observed rather than read once, so flipping the Preferences toggle
	/// re-resolves with the new precedence instead of showing a stale decision.
	@AppStorage(LyricsSettings.useLRCLIBFallbackKey) private var useLRCLIBFallback: Bool = true

	/// Held in `@State` so the resolver is not rebuilt on every body
	/// re-evaluation. Its cache lives on the shared `Session`, so resolved
	/// lyrics survive this view being torn down and rebuilt.
	@State private var resolver: LyricsResolver
	@State private var phase: Phase = .loading
	/// Bumping this restarts the fetch; that is how the retry button works.
	@State private var attempt: Int = 0
	/// Index of the line briefly highlighted after a tap-to-seek.
	@State private var tappedLineIndex: Int?
	@State private var tapResetTask: Task<Void, Never>?
	/// Line the user last tapped, held as the highlighted line until playback
	/// actually reaches it. A seek can land just before the line's timestamp,
	/// and the periodic time observer would then resolve the highlight back to
	/// the previous line; this keeps the tapped line selected in the meantime.
	@State private var selectedLineIndex: Int?

	private enum Phase {
		case loading
		case loaded(LyricsResult)
		case empty
		case failed
	}

	init(session: Session, player: Player, style: Style = .drawer, isVisible: Bool = true) {
		self.session = session
		self.player = player
		self.style = style
		self.isVisible = isVisible
		_resolver = State(initialValue: LyricsResolver(session: session))
	}

	var body: some View {
		VStack(spacing: 0) {
			content
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			if style.showsAttribution, let source = loadedSource {
				attribution(source)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.task(id: fetchKey) {
			await load()
		}
		.onChange(of: playbackInfo.playbackPosition) { _, position in
			// Release the tapped-line override once the player's reported
			// position has caught up and naturally resolves to that line.
			guard let selectedLineIndex,
				  case .loaded(let result) = phase,
				  result.lines.indices.contains(selectedLineIndex),
				  LyricLine.currentIndex(at: position, in: result.lines) == selectedLineIndex else { return }
			self.selectedLineIndex = nil
		}
	}

	// MARK: - State

	private var track: Track? {
		queueInfo.currentItem?.track
	}

	/// Re-runs the fetch when the track, the fallback preference, a manual retry or
	/// the surface's visibility changes.
	private var fetchKey: String {
		"\(track?.id ?? -1)#\(useLRCLIBFallback)#\(attempt)#\(isVisible)"
	}

	/// The provider to credit, only while lyrics are actually rendered.
	private var loadedSource: LyricsSource? {
		guard case .loaded(let result) = phase else { return nil }
		return result.source
	}

	/// Index of the line playing at the current position. `nil` before the first
	/// line, which is why the highlight is optional rather than index 0.
	private var currentLineIndex: Int? {
		guard case .loaded(let result) = phase, !result.lines.isEmpty else { return nil }
		// Prefer the tapped line until playback actually reaches it.
		if let selectedLineIndex, result.lines.indices.contains(selectedLineIndex) {
			return selectedLineIndex
		}
		return LyricLine.currentIndex(at: playbackInfo.playbackPosition, in: result.lines)
	}

	/// Fetches once, then retries a failure on `LyricsRetryPolicy`'s schedule.
	///
	/// The retries live inside this one task and never touch `attempt`: `fetchKey`
	/// stays put while one is pending, so the panel is not restarted under them. Only
	/// the retry button bumps `attempt`, which changes the key, cancels this task
	/// (a sleeping retry included) and starts a fresh schedule. A track change and a
	/// closed surface cancel it the same way, so no retry outlives what asked for it.
	///
	/// The failure state is painted only once the schedule is spent. While a retry is
	/// still due, the skeleton stays: the result is not final yet, and a button that
	/// cancels the schedule would be a trap.
	///
	/// The whole sequence runs under one wall-clock cap, because the waits alone bound
	/// nothing: a provider that never answers spends the request timeout inside each try.
	/// The cap cancels the sequence, attempt in flight included, and what it leaves behind is
	/// a failure, so the longest the skeleton can last is `LyricsRetryPolicy.totalBudget`.
	private func load() async {
		guard isVisible else { return }
		selectedLineIndex = nil
		phase = .loading
		guard let track else {
			phase = .failed
			return
		}
		let sequence = Task { await self.sequence(for: track) }
		let cap = Task {
			try? await Task.sleep(for: LyricsRetryPolicy.totalBudget)
			guard !Task.isCancelled else { return }
			sequence.cancel()
		}
		let outcome = await withTaskCancellationHandler {
			await sequence.value
		} onCancel: {
			// A track change, a closed surface or a manual retry must stop the schedule too.
			sequence.cancel()
		}
		cap.cancel()
		// The view's own task was cancelled: nothing here is worth painting.
		guard !Task.isCancelled else { return }
		switch outcome {
		case .found(let result):
			phase = .loaded(result)
		case .notFound:
			phase = .empty
		case .failed:
			phase = .failed
		}
	}

	/// Tries until an answer arrives, the schedule is spent or the caller cancels. The
	/// outcome is returned rather than painted, so the caller decides what a cancelled
	/// sequence means.
	private func sequence(for track: Track) async -> LyricsOutcome<LyricsResult> {
		var completedTries = 0
		while true {
			let outcome = await resolver.lyrics(for: track, preferLRCLIB: useLRCLIBFallback)
			completedTries += 1
			guard !Task.isCancelled,
				  let delay = LyricsRetryPolicy.retryDelay(afterCompletedTries: completedTries, outcome: outcome) else {
				return outcome
			}
			try? await Task.sleep(for: delay)
			// A wait cut short is a failure the panel should show, which is what the cap
			// leaves behind when it lands here.
			guard !Task.isCancelled else { return .failed }
		}
	}

	// MARK: - States

	@ViewBuilder
	private var content: some View {
		switch phase {
		case .loading:
			loadingSkeleton
		case .loaded(let result):
			if result.lines.isEmpty {
				plainLyrics(result.plainText ?? "")
			} else {
				syncedLyrics(result.lines)
			}
		case .empty:
			emptyState
		case .failed:
			errorState
		}
	}

	/// Timed lyrics. The current line is highlighted and kept vertically centred
	/// as playback advances; scrolling is automatic only, with no manual override.
	private func syncedLyrics(_ lines: [LyricLine]) -> some View {
		GeometryReader { geometry in
			ScrollViewReader { proxy in
				ScrollView(.vertical, showsIndicators: false) {
					LazyVStack(alignment: .leading, spacing: style.lineSpacing) {
						ForEach(lines.indices, id: \.self) { index in
							lyricLine(lines[index], index: index, isCurrent: index == currentLineIndex)
								.id(index)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, style.horizontalPadding)
					// Half a viewport of slack at each end so even the first and
					// last lines can scroll all the way to the centre.
					.padding(.vertical, max(0, geometry.size.height / 2 - style.verticalSlackInset))
				}
				.onChange(of: currentLineIndex, initial: true) { _, index in
					guard let index else { return }
					withAnimation(.easeInOut(duration: 0.35)) {
						proxy.scrollTo(index, anchor: .center)
					}
				}
			}
		}
	}

	private func lyricLine(_ lyric: LyricLine, index: Int, isCurrent: Bool) -> some View {
		Text(lyric.text.isEmpty ? "♪" : lyric.text)
			.font(.system(
				size: isCurrent ? style.currentFontSize : style.otherFontSize,
				weight: isCurrent ? .semibold : .regular
			))
			.foregroundStyle(isCurrent ? Color.controlAccentColor : Color.primary.opacity(0.55))
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 6)
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(tappedLineIndex == index ? Color.controlAccentColor.opacity(0.18) : Color.clear)
			)
			.contentShape(Rectangle())
			.onTapGesture { seek(to: lyric, at: index) }
			.allowsHitTesting(style.allowsSeeking)
			.animation(.easeInOut(duration: 0.2), value: isCurrent)
			.animation(.easeInOut(duration: 0.15), value: tappedLineIndex)
	}

	/// Seeks to a tapped line. `Player.seek(to:)` takes a fraction of the current
	/// item's duration, so the line's timestamp is converted first. The tapped
	/// line is held as the highlight until the player's reported position
	/// catches up, so the periodic observer cannot flip the selection back.
	private func seek(to lyric: LyricLine, at index: Int) {
		guard let track, track.duration > 0 else { return }
		let fraction = min(max(lyric.time / Double(track.duration), 0), 1)
		player.seek(to: fraction)

		selectedLineIndex = index

		tappedLineIndex = index
		tapResetTask?.cancel()
		tapResetTask = Task {
			try? await Task.sleep(for: .milliseconds(280))
			guard !Task.isCancelled else { return }
			tappedLineIndex = nil
		}
	}

	private func plainLyrics(_ text: String) -> some View {
		ScrollView(.vertical, showsIndicators: false) {
			Text(text)
				.font(.system(size: style.otherFontSize))
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(style.horizontalPadding)
		}
	}

	/// Eight placeholder bars matching the loaded state's line rhythm.
	private var loadingSkeleton: some View {
		VStack(alignment: .leading, spacing: style.lineSpacing) {
			ForEach(0..<8, id: \.self) { index in
				RoundedRectangle(cornerRadius: 3, style: .continuous)
					.fill(Color.secondary.opacity(0.16))
					.frame(height: 13)
					.frame(maxWidth: .infinity, alignment: .leading)
					.scaleEffect(x: Self.skeletonWidths[index], anchor: .leading)
			}
			Spacer(minLength: 0)
		}
		.padding(style.horizontalPadding)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	/// Fractional widths so the skeleton reads as text, not as a solid block.
	private static let skeletonWidths: [CGFloat] = [0.92, 0.68, 0.85, 0.55, 0.78, 0.95, 0.62, 0.72]

	private var emptyState: some View {
		terminalState(
			icon: "quote.bubble",
			iconSize: 28,
			message: "No lyrics available"
		)
	}

	private var errorState: some View {
		terminalState(
			icon: "exclamationmark.triangle",
			iconSize: 26,
			message: "Couldn't load lyrics"
		)
	}

	/// A state with nothing to show: an icon, one line of explanation and a
	/// button that refetches. A miss and a failure both end here.
	private func terminalState(
		icon: String,
		iconSize: CGFloat,
		message: String
	) -> some View {
		VStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: iconSize))
				.foregroundStyle(.secondary)
			Text(message)
				.font(.system(size: 14))
				.foregroundStyle(.secondary)
			Button("Try again") {
				attempt += 1
			}
			.buttonStyle(.bordered)
			.controlSize(.small)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	/// Credits the provider that won resolution.
	private func attribution(_ source: LyricsSource) -> some View {
		VStack(spacing: 0) {
			Divider()
				.opacity(0.3)
			Text(Self.attributionText(source))
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, style.horizontalPadding)
				.padding(.vertical, 10)
		}
	}

	/// A file records no provider, so it is credited as the file rather than guessed at.
	private static func attributionText(_ source: LyricsSource) -> String {
		switch source {
		case .tidal:
			"Lyrics from Tidal"
		case .lrclib:
			"Lyrics from LRCLIB"
		case .file:
			"Lyrics from file"
		}
	}
}
