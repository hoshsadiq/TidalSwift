//
//  HiResSessionAccessTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// Pins the one signal that decides whether the hi-res route is available at all:
/// the `cuk` claim in the access token. The token payload is not verified, only read,
/// so these use unsigned fixtures.
@MainActor
final class HiResSessionAccessTests: XCTestCase {
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

	func testTokenWithCukClaimHasHiResAccess() throws {
		XCTAssertTrue(HiResStreamingSession.hasHiResStereoClaim(in: try token(payload: ["uid": 1, "cuk": "client-key"])))
	}

	func testTokenWithoutCukClaimHasNoHiResAccess() throws {
		XCTAssertFalse(HiResStreamingSession.hasHiResStereoClaim(in: try token(payload: ["uid": 1, "cid": 3003])))
	}

	func testMalformedTokenHasNoHiResAccess() {
		XCTAssertFalse(HiResStreamingSession.hasHiResStereoClaim(in: ""))
		XCTAssertFalse(HiResStreamingSession.hasHiResStereoClaim(in: "Bearer not.a.jwt.with.too.many.parts"))
		XCTAssertFalse(HiResStreamingSession.hasHiResStereoClaim(in: "Bearer .notbase64.!"))
	}
}
