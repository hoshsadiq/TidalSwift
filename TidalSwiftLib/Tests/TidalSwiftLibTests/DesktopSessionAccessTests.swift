//
//  DesktopSessionAccessTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the one signal that decides whether Tidal's desktop playback routes are available:
/// the `cuk` claim in the access token. The payload is only read, not verified, so unsigned
/// fixtures do.
@MainActor
final class DesktopSessionAccessTests: XCTestCase {
	private func token(payload: [String: Any]) throws -> String {
		let header = try base64URL(["alg": "RS256", "typ": "JWT"])
		let body = try base64URL(payload)
		return "Bearer \(header).\(body).signature"
	}

	private func base64URL(_ object: [String: Any]) throws -> String {
		let data = try JSONSerialization.data(withJSONObject: object)
		return data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	func testTokenWithCukClaimHasDesktopPlaybackAccess() throws {
		XCTAssertTrue(DesktopSessionAccess.hasDesktopClaim(in: try token(payload: ["uid": 1, "cuk": "client-key"])))
	}

	func testTokenWithoutCukClaimHasNoDesktopPlaybackAccess() throws {
		XCTAssertFalse(DesktopSessionAccess.hasDesktopClaim(in: try token(payload: ["uid": 1, "cid": 3003])))
	}

	func testMalformedTokenHasNoDesktopPlaybackAccess() {
		XCTAssertFalse(DesktopSessionAccess.hasDesktopClaim(in: ""))
		XCTAssertFalse(DesktopSessionAccess.hasDesktopClaim(in: "Bearer not.a.jwt.with.too.many.parts"))
		XCTAssertFalse(DesktopSessionAccess.hasDesktopClaim(in: "Bearer .notbase64.!"))
	}
}
