//
//  DesktopLogin.swift
//  TidalSwiftLib
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import CryptoKit

/// PKCE mechanics for the official desktop client's login; no session or UI state.
public enum DesktopLogin {

	public enum LoginError: LocalizedError {
		case authorizationDenied(error: String, description: String?)
		case invalidCallback
		case timeout
		case exchangeFailed(description: String?)
		case network(underlying: Error)
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

	/// 32 random bytes base64url-encoded give the 43 characters RFC 7636 allows.
	public static func generateCodeVerifier() -> String {
		let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
		return base64URLEncode(bytes)
	}

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
		// The client unique key belongs here as well as on the exchange, which is what the
		// official client does; without it the code comes back bound to another client.
		components.queryItems = [
			URLQueryItem(name: "client_id", value: AuthInformation.DesktopClientID),
			URLQueryItem(name: "client_unique_key", value: clientUniqueKey()),
			URLQueryItem(name: "code_challenge", value: codeChallenge),
			URLQueryItem(name: "code_challenge_method", value: "S256"),
			URLQueryItem(name: "redirect_uri", value: AuthInformation.DesktopRedirectURI),
			URLQueryItem(name: "response_type", value: "code"),
			URLQueryItem(name: "scope", value: AuthInformation.scope)
		]
		return components.url!
	}

	// MARK: - Callback parsing

	/// Extracts the `code` from a `tidal://login/auth` callback, or throws the denial Tidal sent.
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

	/// Kept stable per install, because Tidal treats it as identifying this client.
	static func clientUniqueKey(defaults: UserDefaults = .standard) -> String {
		if let existing = defaults.string(forKey: AuthInformation.DesktopUniqueKeyDefaultsKey) {
			return existing
		}
		let key = UUID().uuidString.lowercased()
		defaults.set(key, forKey: AuthInformation.DesktopUniqueKeyDefaultsKey)
		return key
	}

	/// The desktop client is public (PKCE), so no client secret is sent.
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
