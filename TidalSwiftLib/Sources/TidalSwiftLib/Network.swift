//
//  Network.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 12.03.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import Foundation

struct Response {
	let data: Data
	let statusCode: Int?
	let etag: Int?
}

enum Network {}

extension Network {

	// MARK: - Queries

	enum HttpMethod: String {
		case get = "GET"
		case post = "POST"
		case put = "PUT"
		case delete = "DELETE"
	}

	private static func encodeParameters(_ parameters: [String: String]) -> String {
		let queryItems = parameters.map { URLQueryItem(name: $0, value: $1) }
		var components = URLComponents()
		components.queryItems = queryItems
		return components.percentEncodedQuery ?? ""
	}

	static func request(method: HttpMethod, url: URL, parameters: [String: String], etag: Int? = nil, accessToken: String?, xTidalToken: String?, using session: URLSession = .shared) async throws -> Response {
		var request = URLRequest(url: url)
		request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		request.setValue(AuthInformation.tidalClientUserAgent, forHTTPHeaderField: "User-Agent")
		if let accessToken = accessToken {
			request.setValue(accessToken, forHTTPHeaderField: "Authorization")
		}
		if let xTidalToken = xTidalToken {
			request.setValue(xTidalToken, forHTTPHeaderField: "X-Tidal-Token")
		}
		if let etag = etag {
			request.setValue("\"\(etag)\"", forHTTPHeaderField: "If-None-Match")
		}

		switch method {
		case .get:
			request.httpMethod = "GET"
			// If GET or DELETE, parameters are part of the URL
			let urlString = request.url!.absoluteString + "?" + encodeParameters(parameters)
			request.url = URL(string: urlString)
		case .post:
			request.httpMethod = "POST"
			// If POST or DELETE, parameters are part of the body
			request.httpBody = encodeParameters(parameters).data(using: .utf8)
		case .put:
			request.httpMethod = "PUT"
			// If GET, PUT or DELETE, parameters are part of the URL
			let urlString = request.url!.absoluteString + "?" + encodeParameters(parameters)
			request.url = URL(string: urlString)
		case .delete:
			request.httpMethod = "DELETE"
			// If GET or DELETE, parameters are part of the URL
			let urlString = request.url!.absoluteString + "?" + encodeParameters(parameters)
			request.url = URL(string: urlString)
		}
		#if DEBUG
		logRequest(request)
		#endif

		let (data, response) = try await session.data(for: request)

		let statusCode = (response as? HTTPURLResponse)?.statusCode

		// Get the Etag if it exists
		var etag: Int?
		if let httpURLResponse = response as? HTTPURLResponse,
			let etagString = httpURLResponse.allHeaderFields["Etag"] as? String {
			let etagSubString = etagString.dropFirst().dropLast()
			etag = Int(etagSubString)
		}

		#if DEBUG
		logResponse(request, statusCode: statusCode)
		#endif

		return Response(data: data, statusCode: statusCode, etag: etag)
	}

	static func get(url: URL, parameters: [String: String], accessToken: String?, xTidalToken: String?) async throws -> Response {
		try await request(method: .get, url: url, parameters: parameters, accessToken: accessToken, xTidalToken: xTidalToken)
	}

	static func get<Result: Decodable>(url: URL, parameters: [String: String], accessToken: String?, xTidalToken: String?, decoder: JSONDecoder = .custom) async throws -> Result {
		let response = try await request(method: .get, url: url, parameters: parameters, accessToken: accessToken, xTidalToken: xTidalToken)
		return try decoder.decode(Result.self, from: response.data)
	}

	static func post(url: URL, parameters: [String: String], etag: Int? = nil, accessToken: String?, xTidalToken: String?) async throws -> Response {
		try await request(method: .post, url: url, parameters: parameters, etag: etag, accessToken: accessToken, xTidalToken: xTidalToken)
	}

	static func post<Result: Decodable>(url: URL, parameters: [String: String], etag: Int? = nil, accessToken: String?, xTidalToken: String?, decoder: JSONDecoder = .custom) async throws -> Result {
		let response = try await request(method: .post, url: url, parameters: parameters, etag: etag, accessToken: accessToken, xTidalToken: xTidalToken)
		return try decoder.decode(Result.self, from: response.data)
	}

	static func put(url: URL, parameters: [String: String], etag: Int? = nil, accessToken: String?, xTidalToken: String?) async throws -> Response {
		try await request(method: .put, url: url, parameters: parameters, etag: etag, accessToken: accessToken, xTidalToken: xTidalToken)
	}

	static func delete(url: URL, parameters: [String: String], etag: Int? = nil, accessToken: String?, xTidalToken: String?) async throws -> Response {
		try await request(method: .delete, url: url, parameters: parameters, etag: etag, accessToken: accessToken, xTidalToken: xTidalToken)
	}

	// MARK: - Downloads

	/// Downloads `url` to `path`. Path structure example: path/to/file -> [path, to, file].
	/// Cannot be empty.
	///
	/// A non-2xx response is an error page, not the file, so it is refused and its
	/// temporary download removed rather than stored.
	///
	/// `@concurrent`: the bytes are written off the caller's actor, so the file moves
	/// that follow the await do not run on the main actor. It backs the offline sync's
	/// direct-stream fallback.
	///
	/// `session` is injectable so a test can answer with a fixed status without a
	/// live host.
	@concurrent
	static func download(_ url: URL, path: URL, overwrite: Bool = false, using session: URLSession = .shared) async throws {
//		print("=== Network Download ===")
//		print("Download URL: \(url)")
//		print("Temp Local URL: \(dataUrl)")
//		print("Final Local URL: \(path)")
//		print("=======================")

		try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

		// No need to download if we're not overwriting and file exists
		if !overwrite && FileManager.default.fileExists(atPath: path.relativePath) {
			return
		}

		let (downloadURL, response) = try await session.download(from: url)

		// Otherwise an error page, e.g. for an expired URL, would be stored as the file
		if let statusCode = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(statusCode) {
			try? FileManager.default.removeItem(at: downloadURL)
			throw URLError(.badServerResponse)
		}

		// If we want to overwrite and the file exists, delete the existing file
		if overwrite && FileManager.default.fileExists(atPath: path.relativePath) {
			try FileManager.default.removeItem(at: path)
		}
		try FileManager.default.moveItem(at: downloadURL, to: path)
	}

	// MARK: - Logging

	#if DEBUG
	/// Everything the console may learn about a request: method, path, status. Never
	/// a header and never a body — `Authorization` and `X-Tidal-Token` are
	/// credentials, and a body or a signed URL carries one too.
	private static func logRequest(_ request: URLRequest) {
		print("[NET] \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
	}

	private static func logResponse(_ request: URLRequest, statusCode: Int?) {
		print("[NET] \(request.httpMethod ?? "?") \(request.url?.path ?? "?") -> \(statusCode.map(String.init) ?? "no response")")
	}
	#endif
}
