//
//  InAppBrowserLogin.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import AppKit
import AuthenticationServices
import SwiftUI
import TidalSwiftLib

/// The scheme of the desktop login's `redirect_uri` (`tidal://login/auth`).
private let desktopLoginCallbackScheme = "tidal"

/// Why an in-app browser login stopped, carrying the library's classification so
/// the sheet can continue the chain without reading AuthenticationServices errors
/// itself.
struct InAppBrowserLoginEnded: Error {
	let end: LoginRoutePolicy.SessionEnd
}

/// Holds the window the login sheet is shown in. A box rather than SwiftUI state
/// because `LoginWindowReader` fills it during layout, where writing state is not
/// allowed.
final class LoginWindowBox {
	weak var window: NSWindow?
}

/// Hands the hosting window of the login sheet to `LoginWindowBox`, so the in-app
/// browser anchors to the window the user is looking at rather than to whichever
/// window happens to be key when the login starts.
struct LoginWindowReader: NSViewRepresentable {
	let box: LoginWindowBox

	func makeNSView(context: Context) -> LoginWindowCaptureView {
		LoginWindowCaptureView(box: box)
	}

	func updateNSView(_ nsView: LoginWindowCaptureView, context: Context) {}
}

/// `view.window` is only set once the view is in a window, so the capture happens
/// here rather than at creation.
final class LoginWindowCaptureView: NSView {
	private let box: LoginWindowBox

	init(box: LoginWindowBox) {
		self.box = box
		super.init(frame: .zero)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("LoginWindowCaptureView is created in code")
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		box.window = window
	}
}

/// Runs one Tidal login in a browser window inside the app.
///
/// `ASWebAuthenticationSession` intercepts the `tidal://login/auth` redirect
/// itself — the header allows this through `callbackURLScheme:` — so the login
/// does not depend on this app being the `tidal://` handler, and no LaunchServices
/// race decides it. The session is owned by this object so it stays alive until
/// the callback arrives; a released session never calls back.
final class InAppBrowserLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
	private let anchor: NSWindow
	private var session: ASWebAuthenticationSession?

	init(anchor: NSWindow) {
		self.anchor = anchor
	}

	func presentationAnchor(for session: ASWebAuthenticationSession) -> NSWindow {
		anchor
	}

	/// Shows `url` in the in-app browser and returns the callback it caught.
	/// Throws `InAppBrowserLoginEnded` when the session stopped without one, and
	/// `CancellationError` when the caller gives up.
	func run(url: URL) async throws -> URL {
		let pending = PendingDesktopLogin()
		let session = makeSession(url: url, pending: pending)
		self.session = session
		guard session.start() else {
			self.session = nil
			throw InAppBrowserLoginEnded(end: .unavailable)
		}
		do {
			return try await withTaskCancellationHandler {
				try await pending.wait()
			} onCancel: {
				pending.resume(throwing: CancellationError())
			}
		} catch {
			// Take the browser window down when the wait is abandoned; the session
			// then reports its own cancellation, which nobody is waiting for.
			session.cancel()
			throw error
		}
	}

	/// macOS 14.4 takes the typed callback; 14.0–14.3 use the older initializer
	/// with the scheme. Both hand the matching redirect to the completion handler.
	private func makeSession(url: URL, pending: PendingDesktopLogin) -> ASWebAuthenticationSession {
		let handler: ASWebAuthenticationSession.CompletionHandler = { callbackURL, error in
			if let callbackURL {
				pending.resume(returning: callbackURL)
			} else {
				pending.resume(throwing: error ?? InAppBrowserLoginEnded(end: .failed))
			}
		}
		if #available(macOS 14.4, *) {
			return ASWebAuthenticationSession(
				url: url,
				callback: .customScheme(desktopLoginCallbackScheme),
				completionHandler: handler
			)
		} else {
			return ASWebAuthenticationSession(
				url: url,
				callbackURLScheme: desktopLoginCallbackScheme,
				completionHandler: handler
			)
		}
	}
}
