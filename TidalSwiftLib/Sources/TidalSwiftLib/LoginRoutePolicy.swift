//
//  LoginRoutePolicy.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import AuthenticationServices

/// The order in which the login sheet tries its methods, and what an ended
/// in-app browser session means. Pure and free of windows, so every branch is
/// exercisable without a browser or a user.
public nonisolated enum LoginRoutePolicy {
	/// The login methods, in the order the sheet tries them.
	public enum Route: Equatable, Sendable {
		/// Tidal's page in a browser window inside the app. The session catches
		/// the `tidal://login/auth` redirect itself, so this route needs no
		/// URL-scheme registration.
		case inAppBrowser
		/// Tidal's page in the system browser, whose callback returns over
		/// `tidal://` and so needs this app to be the scheme's handler.
		case systemBrowser
		/// Tidal's device-code flow, which needs no callback and no browser page
		/// of ours.
		case deviceCode
	}

	/// How an in-app browser session ended.
	public enum SessionEnd: Equatable, Sendable {
		case succeeded
		/// The user dismissed the session, or declined macOS's offer to share the
		/// Safari session. A normal cancel, never a failure to report as one.
		case cancelled
		/// The session never started: no presentation context, or an unusable one.
		case unavailable
		/// The session started and then ended for another reason.
		case failed
	}

	/// The route to run after an in-app browser session ends this way, or `nil`
	/// when the session completed the login and nothing follows.
	///
	/// The system browser is only available when the `handleTidalLinks`
	/// preference turned it on and `tidal://` is this app's, because its callback
	/// arrives over that scheme; otherwise the chain skips to the device code.
	/// Cancel and failure both continue down the chain, so no outcome leaves the
	/// sheet waiting on a session that is already over.
	public static func nextRoute(after end: SessionEnd, systemBrowserAvailable: Bool) -> Route? {
		switch end {
		case .succeeded:
			return nil
		case .cancelled, .unavailable, .failed:
			return systemBrowserAvailable ? .systemBrowser : .deviceCode
		}
	}

	/// Reads an `ASWebAuthenticationSession` error as a `SessionEnd`. Anything
	/// from another domain is a failure.
	public static func sessionEnd(for error: Error) -> SessionEnd {
		guard let sessionError = error as? ASWebAuthenticationSessionError else { return .failed }
		switch sessionError.code {
		case .canceledLogin:
			return .cancelled
		case .presentationContextNotProvided, .presentationContextInvalid:
			return .unavailable
		default:
			return .failed
		}
	}
}
