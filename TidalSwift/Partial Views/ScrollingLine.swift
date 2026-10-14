//
//  ScrollingLine.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 13.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// One line of content that scrolls leftwards when it is wider than the space it
/// has, and stays still when it fits.
///
/// It freezes while the pointer is over it or it holds keyboard focus, so the
/// links it carries stay under the pointer, and resumes a moment after both have
/// left. With Reduce Motion on it never moves: the line truncates like any other
/// single line instead.
///
/// The motion is the same linear, endless offset `MixGridItem` uses for its
/// artwork, but driven by `TimelineView` so it can stop and start without
/// jumping. A `repeatForever` animation, which that artwork uses, cannot be
/// paused. The content is laid out twice in a row so the wrap is seamless.
///
/// `identity` names the content: the line starts from the beginning whenever it
/// changes, so a new track's credit does not inherit the previous one's phase.
struct ScrollingLine<Content: View, ID: Hashable>: View {
	private let content: Content
	private let identity: ID
	private let pointsPerSecond: Double
	private let gap: CGFloat

	// Read from SwiftUI's environment, which the system sets from Accessibility ▸
	// Display ▸ Reduce Motion.
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var lineSize: CGSize = .zero
	@State private var availableWidth: CGFloat = 0
	@State private var isHovering = false
	@FocusState private var isFocused: Bool
	@State private var timing = ScrollingLineTiming(anchor: Date())
	@State private var resumeTask: Task<Void, Never>?

	init(
		identity: ID,
		pointsPerSecond: Double = 30,
		gap: CGFloat = 48,
		@ViewBuilder content: () -> Content
	) {
		self.identity = identity
		self.pointsPerSecond = pointsPerSecond
		self.gap = gap
		self.content = content()
	}

	// The width reading starts at zero and the line's own size is only known after
	// a layout pass, so an overflow is claimed only once both are in.
	private var overflows: Bool {
		ScrollingLineTiming.overflows(lineWidth: lineSize.width, availableWidth: availableWidth)
	}
	private var scrolls: Bool { overflows && !reduceMotion }
	private var pauseRequested: Bool { isHovering || isFocused }
	private var loopWidth: CGFloat { lineSize.width + gap }
	private var period: Double {
		ScrollingLineTiming.period(loopWidth: loopWidth, pointsPerSecond: pointsPerSecond)
	}

	var body: some View {
		ZStack(alignment: .leading) {
			// How much space the line was offered. Its own reading, read here rather
			// than from the enclosing view: a preference read above a conditional
			// overlay does not arrive.
			GeometryReader { proxy in
				Color.clear.preference(key: ScrollingLineWidthKey.self, value: proxy.size.width)
			}
			.frame(height: 0)
			.accessibilityHidden(true)
			.onPreferenceChange(ScrollingLineWidthKey.self) { availableWidth = $0 }

			// The line at its natural size, kept out of the layout and read once
			// so the scroll can be gated on whether it actually overflows.
			content
				.fixedSize()
				.background(
					GeometryReader { proxy in
						Color.clear.preference(key: ScrollingLineSizeKey.self, value: proxy.size)
					}
				)
				.hidden()
				.frame(width: 0, height: 0, alignment: .leading)
				.accessibilityHidden(true)
				.onPreferenceChange(ScrollingLineSizeKey.self) { size in
					guard let size else { return }
					let contentChanged = size.width != lineSize.width
					lineSize = size
					// Content measured at a new width is a new line: restart it rather
					// than let it inherit the previous content's phase.
					if contentChanged { restart() }
				}

			// The line itself. It sets the row's height whether or not it scrolls,
			// stays put (and stays clickable) when it fits, and is covered by the
			// scrolling copy when it does not. The overlay never widens the row, so
			// the width reading above still sees the space actually offered.
			content
				.lineLimit(1)
				.truncationMode(.tail)
				.opacity(scrolls ? 0 : 1)
				.accessibilityHidden(scrolls)
				// When the moving copy is on top this one is invisible; it must not
				// stay clickable underneath it.
				.allowsHitTesting(!scrolls)
				.overlay(alignment: .leading) {
					if scrolls {
						TimelineView(.animation(minimumInterval: nil, paused: timing.isPaused)) { context in
							HStack(spacing: gap) {
								content
								content
									.accessibilityHidden(true)
							}
							.fixedSize()
							.offset(x: -displayPhase(at: context.date) * loopWidth)
						}
					}
				}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.clipped()
		.onHover { isHovering = $0 }
		.focusable()
		.focused($isFocused)
		.focusEffectDisabled()
		.onChange(of: identity) { restart() }
		.onChange(of: scrolls) { _, nowScrolling in
			// Start each scroll from the beginning rather than from wherever the
			// line's age happened to land it.
			if nowScrolling { restart() }
		}
		.onChange(of: pauseRequested) { _, requested in
			updatePause(requested)
		}
		.onDisappear { resumeTask?.cancel() }
	}

	/// Puts the line back at the start of its loop, which is what a new identity,
	/// a new measured width and the start of a scroll all want.
	private func restart() {
		timing.restart(at: Date())
	}

	/// Stops the line while a pointer or the keyboard is on it, and starts it
	/// again a moment after both have left, from where it stopped.
	private func updatePause(_ requested: Bool) {
		resumeTask?.cancel()
		if requested {
			guard !timing.isPaused else { return }
			timing.pause(at: Date(), period: period)
		} else {
			resumeTask = Task {
				try? await Task.sleep(for: .milliseconds(600))
				guard !Task.isCancelled else { return }
				timing.resume(at: Date())
			}
		}
	}

	/// The loop fraction to draw. While paused the timeline's frozen date is not
	/// used — the fraction held by the pause is — so a restart on that pause can
	/// drop the line at its start and have it stay there.
	private func displayPhase(at date: Date) -> Double {
		timing.isPaused ? timing.pausedPhase : timing.phase(at: date, period: period)
	}
}

private struct ScrollingLineSizeKey: PreferenceKey {
	static let defaultValue: CGSize? = nil

	// The measurement is written from a `.background`, so the primary view reduces
	// into this key as well, with the default. Keeping an absent contribution from
	// overwriting a real one makes the result order-independent, which the reading
	// needs: SwiftUI does not promise which of the two arrives last.
	static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
		value = nextValue() ?? value
	}
}

private struct ScrollingLineWidthKey: PreferenceKey {
	static let defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}
