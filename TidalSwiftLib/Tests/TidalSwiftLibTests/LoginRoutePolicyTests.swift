//
//  LoginRoutePolicyTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
import AuthenticationServices
@testable import TidalSwiftLib

/// Pins how the login sheet continues after an in-app browser session, and what
/// an `ASWebAuthenticationSession` error means. Both are pure functions, so the
/// whole table is asserted rather than a representative few.
final class LoginRoutePolicyTests: XCTestCase {

	/// The rule, restated independently of the implementation, so a change to
	/// either side that the other does not follow fails here.
	private func expectedNext(
		after end: LoginRoutePolicy.SessionEnd,
		systemBrowserAvailable: Bool
	) -> LoginRoutePolicy.Route? {
		switch end {
		case .succeeded:
			return nil
		case .cancelled, .unavailable, .failed:
			return systemBrowserAvailable ? .systemBrowser : .deviceCode
		}
	}

	/// The whole table: every way a session can end, with and without a usable
	/// system browser.
	func testNextRouteTableForEveryEndAndAvailability() {
		let ends: [LoginRoutePolicy.SessionEnd] = [.succeeded, .cancelled, .unavailable, .failed]
		for end in ends {
			for available in [true, false] {
				XCTAssertEqual(
					LoginRoutePolicy.nextRoute(after: end, systemBrowserAvailable: available),
					expectedNext(after: end, systemBrowserAvailable: available),
					"end=\(end), systemBrowserAvailable=\(available)"
				)
			}
		}
	}

	/// A cancel — including macOS's declined "share your Safari session" alert —
	/// continues down the chain instead of stopping the login.
	func testCancelledLoginFallsThroughInsteadOfStopping() {
		XCTAssertEqual(
			LoginRoutePolicy.nextRoute(after: .cancelled, systemBrowserAvailable: true),
			.systemBrowser
		)
		XCTAssertEqual(
			LoginRoutePolicy.nextRoute(after: .cancelled, systemBrowserAvailable: false),
			.deviceCode
		)
	}

	/// A session that never started is still a reason to try the next method, not
	/// to leave the sheet waiting.
	func testSessionThatCannotStartStillFallsThrough() {
		XCTAssertEqual(
			LoginRoutePolicy.nextRoute(after: .unavailable, systemBrowserAvailable: true),
			.systemBrowser
		)
		XCTAssertEqual(
			LoginRoutePolicy.nextRoute(after: .unavailable, systemBrowserAvailable: false),
			.deviceCode
		)
	}

	/// A completed login has nothing to fall through to.
	func testCompletedLoginHasNoNextRoute() {
		XCTAssertNil(LoginRoutePolicy.nextRoute(after: .succeeded, systemBrowserAvailable: true))
		XCTAssertNil(LoginRoutePolicy.nextRoute(after: .succeeded, systemBrowserAvailable: false))
	}

	/// Dismissing the sheet, or declining the Safari-session alert, is the error
	/// code macOS reports for both.
	func testSessionEndReadsCancelAsNormalCancel() {
		XCTAssertEqual(
			LoginRoutePolicy.sessionEnd(for: ASWebAuthenticationSessionError(.canceledLogin)),
			.cancelled
		)
	}

	/// A missing or unusable presentation context is what makes the session unable
	/// to start at all.
	func testSessionEndReadsPresentationContextErrorsAsUnavailable() {
		XCTAssertEqual(
			LoginRoutePolicy.sessionEnd(for: ASWebAuthenticationSessionError(.presentationContextNotProvided)),
			.unavailable
		)
		XCTAssertEqual(
			LoginRoutePolicy.sessionEnd(for: ASWebAuthenticationSessionError(.presentationContextInvalid)),
			.unavailable
		)
	}

	/// Errors from anywhere else are failures, never cancels.
	func testSessionEndReadsForeignErrorsAsFailed() {
		XCTAssertEqual(
			LoginRoutePolicy.sessionEnd(for: NSError(domain: "io.hosh.TidalSwift", code: 1)),
			.failed
		)
	}
}
