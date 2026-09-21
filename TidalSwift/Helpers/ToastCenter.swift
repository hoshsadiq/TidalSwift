//
//  ToastCenter.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI
import Combine

/// Owns the single transient toast shown over the app shell.
///
/// A new `show` replaces the current message and restarts the dismiss timer, so
/// toasts never stack. Injected at the app shell (`ContentView`) so any view can
/// reach it through `@EnvironmentObject`.
final class ToastCenter: ObservableObject {
	@Published private(set) var message: String?

	/// Shown when a video is clicked before video playback exists.
	static let videoComingSoon = "Video playback is coming soon"

	private var dismissTask: Task<Void, Never>?

	/// Shows `message` for `duration` seconds, replacing any toast already on screen.
	func show(_ message: String, duration: TimeInterval = 2.5) {
		dismissTask?.cancel()
		self.message = message
		dismissTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(duration))
			guard !Task.isCancelled else { return }
			self?.message = nil
		}
	}
}
