//
//  DesktopLoginTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import XCTest
@testable import TidalSwiftLib

/// Pins the browser-free PKCE mechanics: verifier, challenge, authorize URL and callback
/// parsing. The code exchange is a network call, not covered here.
final class DesktopLoginTests: XCTestCase {

	// MARK: - PKCE

	/// RFC 7636 §4.1: 43–128 characters from the unreserved set.
	@MainActor
	func testCodeVerifierIsWithinRFC7636() {
		let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
		for _ in 0..<20 {
			let verifier = DesktopLogin.generateCodeVerifier()
			XCTAssertTrue((43...128).contains(verifier.count), "length \(verifier.count) out of range")
			XCTAssertTrue(
				verifier.unicodeScalars.allSatisfy { unreserved.contains($0) },
				"verifier has a character outside the unreserved set: \(verifier)"
			)
		}
	}

	/// Asserted against the published RFC 7636 Appendix B pair, not the implementation's output.
	@MainActor
	func testCodeChallengeMatchesRFC7636Pair() {
		let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
		let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
		XCTAssertEqual(DesktopLogin.codeChallenge(for: verifier), challenge)
		XCTAssertFalse(challenge.hasSuffix("="), "challenge must be unpadded")
	}

	// MARK: - Authorize URL

	@MainActor
	func testAuthorizeURLCarriesDesktopClientParameters() throws {
		let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
		let url = DesktopLogin.authorizeURL(codeChallenge: challenge)
		let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
		let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

		XCTAssertEqual(url.host(), "login.tidal.com")
		XCTAssertEqual(url.path, "/authorize")
		XCTAssertEqual(query["client_id"], "mhPVJJEBNRzVjr2p")
		XCTAssertEqual(query["redirect_uri"], "tidal://login/auth")
		XCTAssertEqual(query["response_type"], "code")
		XCTAssertEqual(query["scope"], "r_usr+w_usr")
		XCTAssertEqual(query["code_challenge"], challenge)
		XCTAssertEqual(query["code_challenge_method"], "S256")
	}

	// MARK: - Callback parsing

	@MainActor
	func testCallbackParsingYieldsCode() throws {
		let url = try XCTUnwrap(URL(string: "tidal://login/auth?code=abc"))
		XCTAssertEqual(try DesktopLogin.authorizationCode(from: url), "abc")
	}

	@MainActor
	func testCallbackErrorSurfacesDenial() throws {
		let url = try XCTUnwrap(URL(string: "tidal://login/auth?error=access_denied&error_description=User%20denied"))
		XCTAssertThrowsError(try DesktopLogin.authorizationCode(from: url)) { error in
			guard case DesktopLogin.LoginError.authorizationDenied(let code, let description) = error else {
				return XCTFail("expected authorizationDenied, got \(error)")
			}
			XCTAssertEqual(code, "access_denied")
			XCTAssertEqual(description, "User denied")
		}
	}

	@MainActor
	func testCallbackWithoutCodeOrErrorRejected() throws {
		let url = try XCTUnwrap(URL(string: "tidal://login/auth"))
		XCTAssertThrowsError(try DesktopLogin.authorizationCode(from: url)) { error in
			guard case DesktopLogin.LoginError.invalidCallback = error else {
				return XCTFail("expected invalidCallback, got \(error)")
			}
		}
	}

	@MainActor
	func testMalformedCallbackRejected() throws {
		let wrongScheme = try XCTUnwrap(URL(string: "https://login/auth?code=abc"))
		XCTAssertThrowsError(try DesktopLogin.authorizationCode(from: wrongScheme)) { error in
			guard case DesktopLogin.LoginError.invalidCallback = error else {
				return XCTFail("expected invalidCallback, got \(error)")
			}
		}

		let wrongHost = try XCTUnwrap(URL(string: "tidal://other/auth?code=abc"))
		XCTAssertThrowsError(try DesktopLogin.authorizationCode(from: wrongHost)) { error in
			guard case DesktopLogin.LoginError.invalidCallback = error else {
				return XCTFail("expected invalidCallback, got \(error)")
			}
		}
	}
}
