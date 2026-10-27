//
//  TidalLyricsStatusTests.swift
//  TidalSwiftLibTests
//

import Foundation
import XCTest
@testable import TidalSwiftLib

/// Answers the lyrics endpoint with a scripted status and body, so a test can tell a
/// refusal from an outage without a live host.
final class LyricsStatusStubURLProtocol: URLProtocol {
	nonisolated(unsafe) static var status = 200
	nonisolated(unsafe) static var body = ""
	nonisolated(unsafe) static var requestCount = 0

	static func reset(status: Int, body: String) {
		self.status = status
		self.body = body
		requestCount = 0
	}

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		Self.requestCount += 1
		guard let url = request.url,
			  let response = HTTPURLResponse(
				url: url,
				statusCode: Self.status,
				httpVersion: "HTTP/1.1",
				headerFields: ["Content-Type": "application/vnd.api+json"]
			  ) else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}

/// Pins what the Tidal leg reports, because the retry decision depends on it: an outage
/// must reach the panel as `.failed`, and only the API saying "nothing here" may reach it
/// as `.notFound`. An error body decodes to nothing, so reading the status first is the
/// only thing that separates the two.
@MainActor
final class TidalLyricsStatusTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "TidalLyricsStatus")

	private let lyricsBody = """
	{"included": [{"type": "lyrics", "attributes": {"lrcText": "[00:01.00]Line", "text": "Line", "technicalStatus": "OK"}}]}
	"""

	private let emptyBody = #"{"included": []}"#
	private let errorBody = #"{"errors": [{"status": "500", "title": "Internal Server Error"}]}"#

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	private func makeSession() -> Session {
		let session = offlineLibrary.makeSession()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [LyricsStatusStubURLProtocol.self]
		session.requestSession = URLSession(configuration: configuration)
		return session
	}

	func testLyricsAreReturnedFromAPopulatedResponse() async {
		LyricsStatusStubURLProtocol.reset(status: 200, body: lyricsBody)

		let outcome = await makeSession().trackLyrics(trackId: 1)

		XCTAssertEqual(outcome, .found(TidalLyrics(lrc: "[00:01.00]Line", plain: "Line")))
	}

	func testAnEmptyResponseIsAMiss() async {
		LyricsStatusStubURLProtocol.reset(status: 200, body: emptyBody)

		let outcome = await makeSession().trackLyrics(trackId: 2)

		XCTAssertEqual(outcome, .notFound)
	}

	func testAServerErrorWithAJSONBodyIsAFailureNotAMiss() async {
		// The shape that used to read as "no lyrics": a decodable error page.
		LyricsStatusStubURLProtocol.reset(status: 500, body: errorBody)

		let outcome = await makeSession().trackLyrics(trackId: 3)

		XCTAssertEqual(outcome, .failed)
	}

	func testAnErrorPageOfAnotherShapeIsAlsoAFailure() async {
		LyricsStatusStubURLProtocol.reset(status: 502, body: "<html><body>Bad Gateway</body></html>")

		let outcome = await makeSession().trackLyrics(trackId: 4)

		XCTAssertEqual(outcome, .failed)
	}

	func testAMissingTrackIsAMiss() async {
		LyricsStatusStubURLProtocol.reset(status: 404, body: #"{"errors": [{"status": "404"}]}"#)

		let outcome = await makeSession().trackLyrics(trackId: 5)

		XCTAssertEqual(outcome, .notFound)
	}
}
