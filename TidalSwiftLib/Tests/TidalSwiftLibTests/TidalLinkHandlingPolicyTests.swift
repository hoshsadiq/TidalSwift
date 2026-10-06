//
//  TidalLinkHandlingPolicyTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the login route and what it asks of the `tidal://` registration. The rule
/// is preference × who currently handles the scheme, so every combination is
/// asserted rather than a representative few.
final class TidalLinkHandlingPolicyTests: XCTestCase {

	/// The rule, restated independently of the implementation, so a change to
	/// either side that the other does not follow fails here.
	private func expected(
		enabled: Bool,
		handler: TidalLinkHandlingPolicy.SchemeHandler
	) -> TidalLinkHandlingPolicy.Decision {
		if !enabled {
			return .init(route: .device, registration: handler == .thisApp ? .release : .none)
		}
		return .init(route: .browser, registration: handler == .thisApp ? .none : .claim)
	}

	/// The whole table: on and off against each possible handler.
	func testDecisionTableForEveryPreferenceAndHandler() {
		let handlers: [TidalLinkHandlingPolicy.SchemeHandler] = [.thisApp, .anotherApp, .nobody]
		for enabled in [true, false] {
			for handler in handlers {
				XCTAssertEqual(
					TidalLinkHandlingPolicy.decide(enabled: enabled, handler: handler),
					expected(enabled: enabled, handler: handler),
					"enabled=\(enabled), handler=\(handler)"
				)
			}
		}
	}

	/// On: the browser login runs, and the scheme is claimed unless we already hold it.
	func testEnabledRunsBrowserLoginAndClaimsWhenNotAlreadyHeld() {
		XCTAssertEqual(
			TidalLinkHandlingPolicy.decide(enabled: true, handler: .thisApp),
			TidalLinkHandlingPolicy.Decision(route: .browser, registration: .none)
		)
		XCTAssertEqual(
			TidalLinkHandlingPolicy.decide(enabled: true, handler: .anotherApp),
			TidalLinkHandlingPolicy.Decision(route: .browser, registration: .claim)
		)
		XCTAssertEqual(
			TidalLinkHandlingPolicy.decide(enabled: true, handler: .nobody),
			TidalLinkHandlingPolicy.Decision(route: .browser, registration: .claim)
		)
	}

	/// Off: no browser and no 300 s wait; a scheme we hold is handed back, and one
	/// we do not hold is left for its owner.
	func testDisabledRunsDeviceLoginAndReleasesOnlyWhatWeHold() {
		XCTAssertEqual(
			TidalLinkHandlingPolicy.decide(enabled: false, handler: .thisApp),
			TidalLinkHandlingPolicy.Decision(route: .device, registration: .release)
		)
		XCTAssertEqual(
			TidalLinkHandlingPolicy.decide(enabled: false, handler: .anotherApp),
			TidalLinkHandlingPolicy.Decision(route: .device, registration: .none)
		)
		XCTAssertEqual(
			TidalLinkHandlingPolicy.decide(enabled: false, handler: .nobody),
			TidalLinkHandlingPolicy.Decision(route: .device, registration: .none)
		)
	}

	/// Switching the preference on asks for the scheme to be claimed; switching it
	/// off asks for it to be handed back.
	func testTogglingAsksForClaimOrRelease() {
		XCTAssertEqual(TidalLinkHandlingPolicy.registration(enabled: true, handler: .anotherApp), .claim)
		XCTAssertEqual(TidalLinkHandlingPolicy.registration(enabled: true, handler: .nobody), .claim)
		XCTAssertEqual(TidalLinkHandlingPolicy.registration(enabled: false, handler: .thisApp), .release)
	}
}
