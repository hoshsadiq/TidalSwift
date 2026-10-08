//
//  LoginRoutePolicyTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Pins the login chain's order and what an error means.
final class LoginRoutePolicyTests: XCTestCase {

	/// The rule, restated independently of the implementation, so a change to either
	/// side that the other does not follow fails here.
	private func expectedNext(
		after route: LoginRoutePolicy.Route,
		end: LoginRoutePolicy.End
	) -> LoginRoutePolicy.Route? {
		guard end != .cancelled else { return nil }
		return route == .systemBrowser ? .deviceCode : nil
	}

	func testRouteTableForEveryEndAndAvailability() {
		let ends: [LoginRoutePolicy.End] = [.cancelled, .timedOut, .failed]
		for available in [true, false] {
			let start = LoginRoutePolicy.firstRoute(systemBrowserAvailable: available)
			XCTAssertEqual(start, available ? .systemBrowser : .deviceCode, "systemBrowserAvailable=\(available)")
			for end in ends {
				XCTAssertEqual(
					LoginRoutePolicy.nextRoute(after: start, end: end),
					expectedNext(after: start, end: end),
					"route=\(start), end=\(end), systemBrowserAvailable=\(available)"
				)
			}
		}
	}

	func testSystemBrowserStartsAndTheDeviceCodeFollows() {
		XCTAssertEqual(LoginRoutePolicy.firstRoute(systemBrowserAvailable: true), .systemBrowser)
		XCTAssertEqual(LoginRoutePolicy.nextRoute(after: .systemBrowser, end: .timedOut), .deviceCode)
		XCTAssertEqual(LoginRoutePolicy.nextRoute(after: .systemBrowser, end: .failed), .deviceCode)
	}

	func testDeviceCodeIsTheWholeChainWhenTheBrowserCannotReturn() {
		XCTAssertEqual(LoginRoutePolicy.firstRoute(systemBrowserAvailable: false), .deviceCode)
		XCTAssertNil(LoginRoutePolicy.nextRoute(after: .deviceCode, end: .timedOut))
		XCTAssertNil(LoginRoutePolicy.nextRoute(after: .deviceCode, end: .failed))
	}

	/// A cancel — the sheet closing, or a new attempt replacing this one — ends the chain.
	func testCancelEndsTheChain() {
		XCTAssertNil(LoginRoutePolicy.nextRoute(after: .systemBrowser, end: .cancelled))
		XCTAssertNil(LoginRoutePolicy.nextRoute(after: .deviceCode, end: .cancelled))
	}

	func testCancelledTaskIsReadAsCancel() {
		XCTAssertEqual(LoginRoutePolicy.end(for: CancellationError()), .cancelled)
	}

	/// The sheet words a timeout differently from a failure.
	func testLoginTimeoutIsReadAsTimeout() {
		XCTAssertEqual(LoginRoutePolicy.end(for: DesktopLogin.LoginError.timeout), .timedOut)
	}

	/// Only a cancelled task is a cancel, including on an error that wraps a cancellation.
	func testLoginErrorsAreReadAsFailure() {
		XCTAssertEqual(LoginRoutePolicy.end(for: DesktopLogin.LoginError.invalidCallback), .failed)
		XCTAssertEqual(
			LoginRoutePolicy.end(for: DesktopLogin.LoginError.network(underlying: CancellationError())),
			.failed
		)
		XCTAssertEqual(LoginRoutePolicy.end(for: NSError(domain: "io.hosh.TidalSwift", code: 1)), .failed)
	}
}
