//
//  DesktopLogin.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import CryptoKit

/// PKCE mechanics for the official desktop client's login. Holds no session or
/// UI state, so every step (verifier, challenge, authorize URL, callback
/// parsing) can be tested without opening a browser. The one network step, the
/// code exchange, is deliberately not unit-tested; the suite has no seam for it.
public enum DesktopLogin {

	/// One case per step, so a failure is never swallowed and never ambiguous.
	public enum LoginError: LocalizedError {
		/// Tidal denied the authorization and sent `error`/`error_description`.
		case authorizationDenied(error: String, description: String?)
		/// The callback URL is not a well-formed `tidal://login/auth` redirect.
		case invalidCallback
		/// No callback arrived before the login gave up waiting.
		case timeout
		/// The token endpoint refused the exchange.
		case exchangeFailed(description: String?)
		/// The request never reached Tidal.
		case network(underlying: Error)
		/// Tidal answered in a format this app cannot read.
		case unexpectedResponse

		public var errorDescription: String? {
			switch self {
			case .authorizationDenied(_, let description):
				return description ?? "Tidal denied the login"
			case .invalidCallback:
				return "Tidal sent an unexpected login callback"
			case .timeout:
				return "Login timed out. Try again or use device login."
			case .exchangeFailed(let description):
				return description ?? "Tidal rejected the login code"
			case .network:
				return "Couldn't reach Tidal. Check your internet connection."
			case .unexpectedResponse:
				return "Tidal answered in an unexpected format"
			}
		}
	}

	// MARK: - PKCE

	/// A code verifier is 43–128 characters from the RFC 7636 unreserved set.
	/// 32 random bytes base64url-encoded give exactly 43 characters.
	public static func generateCodeVerifier() -> String {
		let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
		return base64URLEncode(bytes)
	}

	/// `base64url(sha256(verifier))`, with the padding stripped.
	public static func codeChallenge(for verifier: String) -> String {
		let digest = SHA256.hash(data: Data(verifier.utf8))
		return base64URLEncode(Data(digest))
	}

	private static func base64URLEncode(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	// MARK: - Authorize URL

	public static func authorizeURL(codeChallenge: String) -> URL {
		var components = URLComponents(string: AuthInformation.DesktopAuthorizeLocation)!
		components.queryItems = [
			URLQueryItem(name: "client_id", value: AuthInformation.DesktopClientID),
			URLQueryItem(name: "code_challenge", value: codeChallenge),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
			URLQueryItem(name: "redirect_uri", value: AuthInformation.DesktopRedirectURI),
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "scope", value: AuthInformation.scope)
		]
		return components.url!
	}

	// MARK: - Callback parsing

	/// Extracts the `code` from a `tidal://login/auth` callback, or throws the
	/// denial Tidal sent. Rejects anything that is not exactly that redirect.
	public static func authorizationCode(from callbackURL: URL) throws -> String {
		guard callbackURL.scheme?.lowercased() == "tidal",
			  callbackURL.host()?.lowercased() == "login",
			  callbackURL.path == "/auth" else {
			throw LoginError.invalidCallback
		}
		guard let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
			throw LoginError.invalidCallback
		}
		if let error = items.first(where: { $0.name == "error" })?.value {
			let description = items.first(where: { $0.name == "error_description" })?.value
			throw LoginError.authorizationDenied(error: error, description: description)
		}
		guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
			throw LoginError.invalidCallback
		}
		return code
	}

	// MARK: - Code exchange

	/// Tidal binds the session to a client unique key, which the official app sends
	/// on the code exchange; captured from its own request. A stable value is kept
	/// per install because the server treats it as identifying this client.
	static func clientUniqueKey(defaults: UserDefaults = .standard) -> String {
		if let existing = defaults.string(forKey: AuthInformation.DesktopUniqueKeyDefaultsKey) {
			return existing
		}
		let key = UUID().uuidString.lowercased()
		defaults.set(key, forKey: AuthInformation.DesktopUniqueKeyDefaultsKey)
		return key
	}

	/// Exchanges the authorization code for a token. The desktop client is
	/// public (PKCE), so no client secret is sent. Returns the same token type
	/// the device-code flow uses.
	static func exchangeAuthorizationCode(code: String, verifier: String) async throws -> TokenSuccessResponse {
		let url = URL(string: AuthInformation.DesktopTokenLocation)!
		let parameters: [String: String] = [
			"grant_type": "authorization_code",
			"client_id": AuthInformation.DesktopClientID,
			"client_unique_key": clientUniqueKey(),
			"code": code,
			"code_verifier": verifier,
			"redirect_uri": AuthInformation.DesktopRedirectURI,
			"scope": AuthInformation.scope.replacingOccurrences(of: "+", with: " ")
		]
		let response: Response
		do {
			response = try await Network.post(url: url, parameters: parameters, accessToken: nil, xTidalToken: nil)
		} catch {
			throw LoginError.network(underlying: error)
		}
		if let success = try? JSONDecoder.custom.decode(TokenSuccessResponse.self, from: response.data) {
			return success
		}
		if let error = try? JSONDecoder.custom.decode(TokenErrorResponse.self, from: response.data) {
			throw LoginError.exchangeFailed(description: error.errorDescription)
		}
		throw LoginError.unexpectedResponse
	}
}
