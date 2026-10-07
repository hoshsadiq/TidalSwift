//
//  TidalLinkHandling.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation

/// The `handleTidalLinks` preference, shared by the app's Preferences toggle, the
/// launch-time registration and the login sheet. Default on, so an absent key claims
/// `tidal://` without a migration step.
public nonisolated enum TidalLinkHandlingPreferences {
	public static let enabledKey = "handleTidalLinks"

	public static let defaultEnabled = true

	public static var isEnabled: Bool {
		isEnabled(in: .standard)
	}

	/// `defaults` is injected so the absent-key default is exercisable.
	static func isEnabled(in defaults: UserDefaults) -> Bool {
		guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
		return defaults.bool(forKey: enabledKey)
	}
}

/// Pure rule for how a login runs and what to do with the `tidal://` registration,
/// from the preference and the current handler. The app target carries it out.
public nonisolated enum TidalLinkHandlingPolicy {
	/// Who macOS would hand a `tidal://` link to right now.
	public enum SchemeHandler: Equatable {
		case thisApp
		case anotherApp
		/// No installed app claims the scheme; the check cannot tell more.
		case nobody
	}

	public enum Route: Equatable {
		/// The browser PKCE login; its callback arrives over `tidal://`.
		case browser
		case device
	}

	public enum Registration: Equatable {
		case none
		case claim
		/// Hand the scheme back to the official app when it is installed.
		case release
	}

	public struct Decision: Equatable {
		public let route: Route
		public let registration: Registration
	}

	/// The whole rule; `registration(enabled:handler:)` returns a slice of it.
	public static func decide(enabled: Bool, handler: SchemeHandler) -> Decision {
		guard enabled else {
			return Decision(route: .device, registration: handler == .thisApp ? .release : .none)
		}
		return Decision(route: .browser, registration: handler == .thisApp ? .none : .claim)
	}

	/// The registration half of `decide`, for the launch and toggle paths.
	public static func registration(enabled: Bool, handler: SchemeHandler) -> Registration {
		decide(enabled: enabled, handler: handler).registration
	}
}
