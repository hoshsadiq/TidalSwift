//
//  NetworkDownloadTests.swift
//  TidalSwiftLibTests
//
//  Created by TidalSwift Contributors on 06.10.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import Foundation
import XCTest
@testable import TidalSwiftLib

/// Answers every request with a status chosen by the URL path (`/ok` is 200, anything
/// else 404), so `Network.download`'s refusal can be tested without a live host.
class StatusURLProtocol: URLProtocol {
	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url,
			  let response = HTTPURLResponse(
			  	url: url,
			  	statusCode: url.path.hasSuffix("/ok") ? 200 : 404,
			  	httpVersion: "HTTP/1.1",
			  	headerFields: nil
			  ) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data("body".utf8))
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

final class NetworkDownloadTests: XCTestCase {
	private var root: URL!

	override func setUp() {
		super.setUp()
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("NetworkDownloadTests-\(UUID().uuidString)", isDirectory: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: root)
		super.tearDown()
	}

	private func stubSession() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StatusURLProtocol.self]
		return URLSession(configuration: configuration)
	}

	/// A non-2xx response is an error page, not the file: it must be refused, not
	/// stored, and nothing may be left at the destination.
	func testDownloadRefusesANonSuccessResponseWithoutWritingAFile() async throws {
		let path = root.appendingPathComponent("track.flac")
		do {
			try await Network.download(
				URL(string: "https://stub.invalid/refused")!,
				path: path,
				using: stubSession()
			)
			XCTFail("a non-2xx response must not be stored as the file")
		} catch let error as URLError {
			XCTAssertEqual(error.code, .badServerResponse)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
	}

	func testDownloadWritesTheFileOnASuccessResponse() async throws {
		let path = root.appendingPathComponent("track.flac")
		try await Network.download(
			URL(string: "https://stub.invalid/ok")!,
			path: path,
			using: stubSession()
		)
		XCTAssertEqual(try Data(contentsOf: path), Data("body".utf8))
	}
}
