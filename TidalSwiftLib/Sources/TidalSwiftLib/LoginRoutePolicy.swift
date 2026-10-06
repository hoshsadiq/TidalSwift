//
//  LoginRoutePolicy.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

/// The login methods, in the order the sheet tries them, and what a method that
/// stopped without completing the login means. Pure and free of browsers and
/// windows, so every branch is exercisable without a login.
public nonisolated enum LoginRoutePolicy {
	/// The login methods, in the order the sheet tries them.
	public enum Route: Equatable, Sendable {
		/// Tidal's page in the system browser. Its `tidal://login/auth` callback
		/// reaches the app only while this app is the handler of that scheme.
		case systemBrowser
		/// Tidal's device-code flow, which needs no callback and no browser page of
		/// ours.
		case deviceCode
	}

	/// Why a method stopped without completing the login.
	public enum End: Equatable, Sendable {
		/// The sheet closed, or a new attempt replaced this one. The user is gone: a
		/// normal cancel, never a failure to report.
		case cancelled
		/// The browser page was opened, but no callback reached the app in time.
		case timedOut
		/// Anything else.
		case failed
	}

	/// The method the sheet starts with.
	///
	/// The browser only runs when the `handleTidalLinks` preference makes `tidal://`
	/// this app's, because that is what brings its callback back here; otherwise the
	/// device code runs straight away and no page of ours is opened at all.
	public static func firstRoute(systemBrowserAvailable: Bool) -> Route {
		systemBrowserAvailable ? .systemBrowser : .deviceCode
	}

	/// The method to run after `route` stopped without completing the login, or nil
	/// when the chain is over. The browser is followed by the device code, and a
	/// cancel ends the chain — nothing starts behind the user's back.
	public static func nextRoute(after route: Route, end: End) -> Route? {
		guard end != .cancelled else { return nil }
		switch route {
		case .systemBrowser:
			return .deviceCode
		case .deviceCode:
			return nil
		}
	}

	/// Reads an error as an `End`. A cancelled task is the sheet closing or an attempt
	/// being replaced, which is not a failure; the login's own timeout is its own end
	/// because the sheet words it differently from a failure.
	public static func end(for error: Error) -> End {
		if error is CancellationError { return .cancelled }
		if let loginError = error as? DesktopLogin.LoginError, case .timeout = loginError { return .timedOut }
		return .failed
	}
}
