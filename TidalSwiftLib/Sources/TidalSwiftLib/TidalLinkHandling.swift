//
//  TidalLinkHandling.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

/// The `handleTidalLinks` preference, owned by the library so the app's
/// Preferences toggle, the launch-time registration and the login sheet all read
/// one value.
///
/// Default on: an absent key reads as on, so an existing install claims `tidal://`
/// without a migration step.
public nonisolated enum TidalLinkHandlingPreferences {
	/// The Preferences toggle. One spelling, shared with the app target.
	public static let enabledKey = "handleTidalLinks"

	/// The value used when nothing is stored.
	public static let defaultEnabled = true

	public static var isEnabled: Bool {
		isEnabled(in: .standard)
	}

	/// `defaults` is injected so the absent-key default can be exercised without
	/// touching the real store.
	static func isEnabled(in defaults: UserDefaults) -> Bool {
		guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
		return defaults.bool(forKey: enabledKey)
	}
}

/// Decides how a login runs and what to do with the `tidal://` registration. The
/// rule is a pure function of the preference and who currently handles the scheme,
/// so it can be exercised without a view, a store or LaunchServices. The app target
/// reads the handler and carries the registration out.
public nonisolated enum TidalLinkHandlingPolicy {
	/// Who macOS would hand a `tidal://` link to right now.
	public enum SchemeHandler: Equatable {
		/// This app is the handler.
		case thisApp
		/// Another app is the handler, in practice the official TIDAL desktop app.
		case anotherApp
		/// No installed app claims the scheme, so the check cannot tell.
		case nobody
	}

	/// Which login the sheet runs.
	public enum Route: Equatable {
		/// The browser PKCE login, whose callback arrives over `tidal://`.
		case browser
		/// The device-code login, which needs no callback.
		case device
	}

	/// What to do with the `tidal://` registration.
	public enum Registration: Equatable {
		/// Leave the registration alone.
		case none
		/// Ask the system to make this app the handler.
		case claim
		/// Hand the scheme back to the official app when it is installed.
		case release
	}

	public struct Decision: Equatable {
		public let route: Route
		public let registration: Registration
	}

	/// The whole rule.
	///
	/// On: the browser login runs, and the scheme is claimed unless this app already
	/// holds it. Off: the device login runs straight away, and a scheme this app
	/// holds is handed back so the official app gets its links again.
	public static func decide(enabled: Bool, handler: SchemeHandler) -> Decision {
		guard enabled else {
			return Decision(route: .device, registration: handler == .thisApp ? .release : .none)
		}
		return Decision(route: .browser, registration: handler == .thisApp ? .none : .claim)
	}

	/// The registration half of `decide`, for the launch and toggle paths that only
	/// need to change the handler.
	public static func registration(enabled: Bool, handler: SchemeHandler) -> Registration {
		decide(enabled: enabled, handler: handler).registration
	}
}
