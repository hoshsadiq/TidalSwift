//
//  LRCLIBRequestTests.swift
//  TidalSwiftLibTests
//

import Foundation
import XCTest
@testable import TidalSwiftLib

/// Answers every LRCLIB request with a scripted status code, so the retry the
/// lyrics leg makes after a transient failure is exercised end to end without a
/// live host.
final class LRCLIBStubURLProtocol: URLProtocol {
	/// Statuses served in order. The last one repeats once the script runs out,
	/// so a test can say "503, then 200" or "503 every time".
	nonisolated(unsafe) static var scriptedStatuses: [Int] = [200]
	nonisolated(unsafe) static var body = ""
	nonisolated(unsafe) static var extraHeaders: [String: String] = [:]
	/// Path of every request, in order, so a retry can be told from a search.
	nonisolated(unsafe) static var requestedPaths: [String] = []

	static func reset(statuses: [Int], body: String = "{}", headers: [String: String] = [:]) {
		scriptedStatuses = statuses
		self.body = body
		extraHeaders = headers
		requestedPaths = []
	}

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		Self.requestedPaths.append(url.path)
		let index = Self.requestedPaths.count - 1
		let status = index < Self.scriptedStatuses.count
			? Self.scriptedStatuses[index]
			: Self.scriptedStatuses.last ?? 500
		guard let response = HTTPURLResponse(
			url: url,
			statusCode: status,
			httpVersion: "HTTP/1.1",
			headerFields: Self.extraHeaders
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

/// Pins the LRCLIB leg's own behaviour: one bounded retry after a transient
/// failure, no retry after a refusal, and `Retry-After` still honoured. Without
/// these, deleting the retry would leave every test green.
@MainActor
final class LRCLIBRequestTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "LRCLIBRequest")

	private let record = """
	{"duration": 273.0, "instrumental": false, "plainLyrics": "Plain line", "syncedLyrics": "[00:01.00]Synced line"}
	"""

	private let instrumentalRecord = """
	{"duration": 273.0, "instrumental": true, "plainLyrics": null, "syncedLyrics": null}
	"""

	override func tearDown() {
		offlineLibrary.remove()
		LRCLIBStubURLProtocol.reset(statuses: [200])
		super.tearDown()
	}

	/// A session whose LRCLIB traffic lands on the stub. The offline root is
	/// temporary, so nothing a test does touches the real library.
	private func makeSession() -> Session {
		let session = offlineLibrary.makeSession()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [LRCLIBStubURLProtocol.self]
		session.requestSession = URLSession(configuration: configuration)
		return session
	}

	private func fetchLyrics(_ session: Session) async -> LyricsOutcome<LRCLIBLyrics> {
		await session.lrclibLyrics(trackName: "T", artistName: "A", albumName: "B", duration: 273)
	}

	func testATransientServerFailureIsRetriedOnce() async {
		LRCLIBStubURLProtocol.reset(statuses: [503, 200], body: record)

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .found(LRCLIBLyrics(lrc: "[00:01.00]Synced line", plain: "Plain line")))
		XCTAssertEqual(LRCLIBStubURLProtocol.requestedPaths.count, 2)
	}

	func testAPersistentServerFailureGivesUpAfterOneRetry() async {
		LRCLIBStubURLProtocol.reset(statuses: [503])

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .failed)
		XCTAssertEqual(LRCLIBStubURLProtocol.requestedPaths.count, 2)
	}

	func testAClientErrorIsNotRetried() async {
		LRCLIBStubURLProtocol.reset(statuses: [400])

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .failed)
		XCTAssertEqual(LRCLIBStubURLProtocol.requestedPaths.count, 1)
	}

	func testARateLimitedRequestHonoursRetryAfterAndRetriesOnce() async {
		LRCLIBStubURLProtocol.reset(statuses: [429, 200], body: record, headers: ["Retry-After": "0"])

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .found(LRCLIBLyrics(lrc: "[00:01.00]Synced line", plain: "Plain line")))
		XCTAssertEqual(LRCLIBStubURLProtocol.requestedPaths.count, 2)
	}

	func testANonFiniteRetryAfterIsIgnoredRatherThanTrap() async {
		// `Double("NaN")` parses, and `Duration(seconds: .nan)` traps, so a server
		// that answers this must not be able to take the fetch down with it.
		LRCLIBStubURLProtocol.reset(statuses: [429, 200], body: record, headers: ["Retry-After": "NaN"])

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .found(LRCLIBLyrics(lrc: "[00:01.00]Synced line", plain: "Plain line")))
		XCTAssertEqual(LRCLIBStubURLProtocol.requestedPaths.count, 2)
	}

	func testAnInstrumentalRecordIsAMissAndDoesNotSearch() async {
		LRCLIBStubURLProtocol.reset(statuses: [200], body: instrumentalRecord)

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .notFound)
		XCTAssertEqual(LRCLIBStubURLProtocol.requestedPaths, ["/api/get"])
	}

	func testAnUnreadableBodyIsAFailure() async {
		LRCLIBStubURLProtocol.reset(statuses: [200], body: "not json")

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .failed)
	}

	func testAMissingRecordFallsBackToSearch() async {
		LRCLIBStubURLProtocol.reset(statuses: [404, 200], body: "[\(record)]")

		let outcome = await fetchLyrics(makeSession())

		XCTAssertEqual(outcome, .found(LRCLIBLyrics(lrc: "[00:01.00]Synced line", plain: "Plain line")))
		XCTAssertEqual(LRCLIBStubURLProtocol.requestedPaths, ["/api/get", "/api/search"])
	}

	func testRetryPolicyIsOneMoreAskForTransientFailuresOnly() {
		// A 429 states how long to wait before the second ask.
		XCTAssertEqual(Session.retryDelay(for: .rateLimited(after: .seconds(2))), .seconds(2))
		// A 5xx and a transport failure are blips.
		XCTAssertEqual(Session.retryDelay(for: .failure(statusCode: 500)), .milliseconds(500))
		XCTAssertEqual(Session.retryDelay(for: .failure(statusCode: 503)), .milliseconds(500))
		XCTAssertEqual(Session.retryDelay(for: .failure(statusCode: nil)), .milliseconds(500))
		// A timeout is worth one more ask, like the 5xx it often arrives beside.
		XCTAssertEqual(Session.retryDelay(for: .failure(statusCode: 408)), .milliseconds(500))
		// A refusal and an answer are final.
		XCTAssertNil(Session.retryDelay(for: .failure(statusCode: 400)))
		XCTAssertNil(Session.retryDelay(for: .failure(statusCode: 425)))
		XCTAssertNil(Session.retryDelay(for: .notFound))
		XCTAssertNil(Session.retryDelay(for: .success(Data())))
	}

	func testRetryAfterIsFlooredAndCapped() throws {
		func delay(_ header: String?) throws -> Duration {
			var headers: [String: String] = [:]
			if let header { headers["Retry-After"] = header }
			let response = try XCTUnwrap(HTTPURLResponse(
				url: try XCTUnwrap(URL(string: "https://stub.invalid/api/get")),
				statusCode: 429,
				httpVersion: "HTTP/1.1",
				headerFields: headers
			))
			return Session.retryAfter(from: response)
		}

		XCTAssertEqual(try delay("3"), .seconds(3))
		// Never sooner than the gap LRCLIB documents between requests.
		XCTAssertEqual(try delay("0"), .seconds(0.2))
		XCTAssertEqual(try delay("-5"), .seconds(0.2))
		// Never longer than a panel is worth waiting for.
		XCTAssertEqual(try delay("1e9"), .seconds(30))
		// A non-finite value must not trap `Duration(seconds:)`.
		XCTAssertEqual(try delay("NaN"), .seconds(1))
		XCTAssertEqual(try delay(nil), .seconds(1))
	}

	// MARK: - Pacing after a rate limit

	func testAQuietWindowHoldsTheNextRequest() async {
		// A stated wait belongs to the host, not to one surface: with the lyrics panel
		// retrying a failure within seconds, only the shared throttle can keep the next
		// request behind the wait LRCLIB asked for.
		let throttle = LRCLIBThrottle()
		await throttle.quiet(for: .milliseconds(300))
		let start = ContinuousClock.now

		_ = await throttle.perform { 1 }

		XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(250))
	}

	func testTheLongerOfTwoQuietWindowsWins() async {
		let throttle = LRCLIBThrottle()
		await throttle.quiet(for: .milliseconds(400))
		await throttle.quiet(for: .milliseconds(50))
		let start = ContinuousClock.now

		_ = await throttle.perform { 1 }

		XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(350))
	}

	func testARequestWithoutAQuietWindowGoesStraightOut() async {
		let throttle = LRCLIBThrottle()
		let start = ContinuousClock.now

		_ = await throttle.perform { 1 }

		XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(200))
	}
}
