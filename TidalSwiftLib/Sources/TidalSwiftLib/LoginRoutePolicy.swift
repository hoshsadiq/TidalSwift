//
//  LoginRoutePolicy.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

public nonisolated enum LoginRoutePolicy {
	public enum Route: Equatable, Sendable {
		/// Its `tidal://login/auth` callback reaches the app only while this app handles
		/// the scheme.
		case systemBrowser
		case deviceCode
	}

	public enum End: Equatable, Sendable {
		/// The sheet closed, or a new attempt replaced this one: a normal cancel, not a failure.
		case cancelled
		case timedOut
		case failed
	}

	/// The browser runs only when the `handleTidalLinks` preference makes `tidal://` this
	/// app's, since that is what returns its callback.
	public static func firstRoute(systemBrowserAvailable: Bool) -> Route {
		systemBrowserAvailable ? .systemBrowser : .deviceCode
	}

	/// The browser is followed by the device code; a cancel ends the chain.
	public static func nextRoute(after route: Route, end: End) -> Route? {
		guard end != .cancelled else { return nil }
		switch route {
		case .systemBrowser:
			return .deviceCode
		case .deviceCode:
			return nil
		}
	}

	/// Cancellation is the sheet closing, not a failure; the timeout stays separate because
	/// the sheet words it differently.
	public static func end(for error: Error) -> End {
		if error is CancellationError { return .cancelled }
		if let loginError = error as? DesktopLogin.LoginError, case .timeout = loginError { return .timedOut }
		return .failed
	}
}
