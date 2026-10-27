//
//  OfflineEmbeddedLyricsTests.swift
//  TidalSwiftLibTests
//

import Foundation
import XCTest
@testable import TidalSwiftLib

/// The offline library is the store a play reads, so its file is the one whose lyrics matter.
/// These pin that a file in the library is found by track id and that its embedded lyrics come
/// back through the same path the resolver uses.
@MainActor
final class OfflineEmbeddedLyricsTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineEmbeddedLyrics")

	private var libraryFolder: URL {
		offlineLibrary.root.appendingPathComponent("TidalSwift Offline Library", isDirectory: true)
	}

	override func tearDown() {
		offlineLibrary.remove()
		super.tearDown()
	}

	private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
		try XCTUnwrap(
			Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
			"Missing fixture \(name).\(ext)"
		)
	}

	private func tags(lyrics: String?) -> AudioTags {
		AudioTags(
			title: "Test Track",
			artist: "Tester",
			album: "Test Album",
			albumArtist: nil,
			trackNumber: 1,
			trackTotal: nil,
			discNumber: 1,
			discTotal: nil,
			releaseDate: nil,
			copyright: nil,
			isrc: nil,
			isCompilation: false,
			isExplicit: false,
			cover: nil,
			lyrics: lyrics
		)
	}

	/// The library names a file `<track id>.<variant>.<ext>`, which is what the listing parses.
	private func storedFile(trackId: Int, extension pathExtension: String) throws -> URL {
		try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
		let url = libraryFolder.appendingPathComponent("\(trackId).\(pathExtension)")
		try FileManager.default.copyItem(at: try fixtureURL("silent", pathExtension), to: url)
		return url
	}

	func testAStoredLibraryFileIsFoundByTrackId() async throws {
		let trackId = 642_000_001
		let file = try storedFile(trackId: trackId, extension: "flac")
		try await FLACTagWriter.write(tags(lyrics: "[00:02.00]From the library"), to: file)
		let offline = offlineLibrary.makeSession().helpers.offline

		let found = offline.storedFile(forTrackId: trackId)

		XCTAssertEqual(found?.lastPathComponent, file.lastPathComponent)
		XCTAssertNil(offline.storedFile(forTrackId: trackId + 1), "an id with no file is not found")
	}

	func testTheLibraryFileCarriesLyricsTheResolverCanRead() async throws {
		let trackId = 642_000_002
		let file = try storedFile(trackId: trackId, extension: "flac")
		try await FLACTagWriter.write(tags(lyrics: "[00:02.00]From the library"), to: file)
		let session = offlineLibrary.makeSession()
		// Neither provider may be reached: the file answers on its own.
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [LyricsStatusStubURLProtocol.self]
		session.requestSession = URLSession(configuration: configuration)
		LyricsStatusStubURLProtocol.reset(status: 500, body: "")

		let outcome = await LyricsResolver(session: session).lyrics(
			for: LyricsQuery(trackId: trackId, title: "Test Track", artistName: "Tester", albumName: "Test Album", duration: 1),
			preferLRCLIB: true
		)

		guard case .found(let result) = outcome else {
			return XCTFail("the library file should answer, got \(outcome)")
		}
		XCTAssertEqual(result.lines.map(\.text), ["From the library"])
		XCTAssertEqual(result.source, .file)
		XCTAssertEqual(LyricsStatusStubURLProtocol.requestCount, 0, "no provider is asked for a track the library already has")
	}

	func testAnUntaggedLibraryFileFallsThroughToTheProviders() async throws {
		let trackId = 642_000_003
		_ = try storedFile(trackId: trackId, extension: "flac")
		let session = offlineLibrary.makeSession()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [LyricsStatusStubURLProtocol.self]
		session.requestSession = URLSession(configuration: configuration)
		LyricsStatusStubURLProtocol.reset(status: 404, body: "")

		let outcome = await LyricsResolver(session: session).lyrics(
			for: LyricsQuery(trackId: trackId, title: "Test Track", artistName: "Tester", albumName: "Test Album", duration: 1),
			preferLRCLIB: true
		)

		// A 404 is a miss rather than a failure, and the file had nothing, so the answer is a miss.
		XCTAssertEqual(outcome, .notFound)
		// Tidal, then LRCLIB's two legs, which the stub also answers.
		XCTAssertGreaterThan(LyricsStatusStubURLProtocol.requestCount, 0, "an untagged file sends the resolver on to the providers")
	}
}
