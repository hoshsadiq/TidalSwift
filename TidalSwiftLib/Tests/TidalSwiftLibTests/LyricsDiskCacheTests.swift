//
//  LyricsDiskCacheTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// A throwaway lyrics-cache folder, so no test reads or writes the real one in the
/// container's caches directory.
private struct TemporaryLyricsCache {
	let root: URL

	init() {
		root = FileManager.default.temporaryDirectory
			.appendingPathComponent("TidalSwiftTests-lyrics-\(UUID().uuidString)", isDirectory: true)
	}

	func makeCache(budgetBytes: Int = LyricsDiskCache.budgetBytes) -> LyricsDiskCache {
		LyricsDiskCache(directory: root, budgetBytes: budgetBytes)
	}

	func fileNames() -> [String] {
		((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
	}

	func fileSize(_ name: String) -> Int {
		(((try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)) ?? [:])[.size] as? Int) ?? 0
	}

	func backdate(_ name: String, to date: Date) {
		try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(name).path)
	}

	/// Writes a document of `size` bytes, so a test can budget by hand.
	func writeRawFile(trackId: Int, size: Int, lastUsed: Date) {
		try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let url = root.appendingPathComponent("\(trackId)-lyrics.json")
		try? Data(repeating: 0x20, count: size).write(to: url)
		try? FileManager.default.setAttributes([.modificationDate: lastUsed], ofItemAtPath: url.path)
	}

	func fileURL(_ name: String) -> URL {
		root.appendingPathComponent(name)
	}

	func remove() {
		try? FileManager.default.removeItem(at: root)
	}
}

final class LyricsDiskCacheTests: XCTestCase {
	private var temporary: TemporaryLyricsCache!

	override func setUp() {
		super.setUp()
		temporary = TemporaryLyricsCache()
	}

	override func tearDown() {
		temporary.remove()
		temporary = nil
		super.tearDown()
	}

	private func result(source: LyricsSource = .tidal, plain: String? = "plain") -> LyricsResult {
		LyricsResult(lines: [LyricLine(time: 1.5, text: "line")], plainText: plain, source: source)
	}

	// MARK: - Round trip

	func testStoredResultIsServedFromDisk() async {
		let cache = temporary.makeCache()
		let stored = result()

		await cache.store(stored, trackId: 42, preferLRCLIB: true)

		guard case .hit(let served) = await cache.lookup(trackId: 42, preferLRCLIB: true) else {
			return XCTFail("expected a disk hit")
		}
		XCTAssertEqual(served, stored)
		XCTAssertEqual(served.lines.first?.time, 1.5)
	}

	func testPlainOnlyResultKeepsItsText() async {
		let cache = temporary.makeCache()
		let stored = LyricsResult(lines: [], plainText: "just words", source: .lrclib)

		await cache.store(stored, trackId: 7, preferLRCLIB: true)

		guard case .hit(let served) = await cache.lookup(trackId: 7, preferLRCLIB: true) else {
			return XCTFail("expected a disk hit")
		}
		XCTAssertEqual(served, stored)
	}

	func testUnknownTrackIsAMiss() async {
		let cache = temporary.makeCache()

		guard case .miss = await cache.lookup(trackId: 1, preferLRCLIB: true) else {
			return XCTFail("expected a miss")
		}
	}

	// MARK: - Preference

	func testTheOtherPreferenceIsAMiss() async {
		let cache = temporary.makeCache()
		await cache.store(result(), trackId: 5, preferLRCLIB: true)

		guard case .miss = await cache.lookup(trackId: 5, preferLRCLIB: false) else {
			return XCTFail("a result resolved with the fallback on must not serve a lookup with it off")
		}
	}

	func testANewResultOverwritesTheEntry() async {
		let cache = temporary.makeCache()
		await cache.store(result(source: .tidal), trackId: 3, preferLRCLIB: true)
		let replacement = result(source: .lrclib, plain: "other")
		await cache.store(replacement, trackId: 3, preferLRCLIB: false)

		guard case .miss = await cache.lookup(trackId: 3, preferLRCLIB: true) else {
			return XCTFail("the replaced entry must not answer under its old preference")
		}
		guard case .hit(let served) = await cache.lookup(trackId: 3, preferLRCLIB: false) else {
			return XCTFail("expected the replacement")
		}
		XCTAssertEqual(served, replacement)
		XCTAssertEqual(temporary.fileNames(), ["3-lyrics.json"])
	}

	func testAnUnreadableDocumentIsDroppedAndReadAsAMiss() async {
		let cache = temporary.makeCache()
		temporary.writeRawFile(trackId: 9, size: 40, lastUsed: Date())

		guard case .miss = await cache.lookup(trackId: 9, preferLRCLIB: true) else {
			return XCTFail("expected a miss")
		}
		XCTAssertEqual(temporary.fileNames(), [], "a file nothing can decode should not keep taking space")
	}

	func testADocumentLargerThanTheCapIsDroppedUnread() async {
		let cache = temporary.makeCache()
		temporary.writeRawFile(trackId: 15, size: LyricsDiskCache.maxDocumentBytes + 1, lastUsed: Date())

		guard case .miss = await cache.lookup(trackId: 15, preferLRCLIB: true) else {
			return XCTFail("expected a miss")
		}
		XCTAssertEqual(temporary.fileNames(), [])
	}

	func testAnOversizedResultIsNotWritten() async {
		let cache = temporary.makeCache()
		let huge = LyricsResult(
			lines: [],
			plainText: String(repeating: "a", count: LyricsDiskCache.maxDocumentBytes + 1),
			source: .tidal
		)

		await cache.store(huge, trackId: 16, preferLRCLIB: true)

		XCTAssertEqual(temporary.fileNames(), [])
	}

	func testALinkIsNotFollowedAndIsDropped() async {
		// A document is only served when it is a regular file this cache could have written.
		let cache = temporary.makeCache()
		try? FileManager.default.createDirectory(at: temporary.root, withIntermediateDirectories: true)
		let target = temporary.root.appendingPathComponent("outside.json")
		try? Data("{}".utf8).write(to: target)
		try? FileManager.default.createSymbolicLink(at: temporary.fileURL("17-lyrics.json"), withDestinationURL: target)

		guard case .miss = await cache.lookup(trackId: 17, preferLRCLIB: true) else {
			return XCTFail("expected a miss")
		}
		XCTAssertEqual(temporary.fileNames(), ["outside.json"], "the link goes, the target it pointed at stays")
	}

	func testANonPositiveTrackIdIsNeitherWrittenNorServed() async {
		// A name without a leading track id is invisible to the eviction table, so it
		// would sit in the folder for ever.
		let cache = temporary.makeCache()

		await cache.store(result(), trackId: 0, preferLRCLIB: true)
		await cache.store(result(), trackId: -5, preferLRCLIB: true)

		XCTAssertEqual(temporary.fileNames(), [])
		guard case .miss = await cache.lookup(trackId: -5, preferLRCLIB: true) else {
			return XCTFail("expected a miss")
		}
	}

	// MARK: - Eviction

	func testStoringPrunesTheFolder() async {
		// Sized from a real document, so the budget holds one and not two.
		await temporary.makeCache().store(result(), trackId: 1, preferLRCLIB: true)
		let oneFile = temporary.fileSize("1-lyrics.json")
		XCTAssertGreaterThan(oneFile, 0)
		let cache = temporary.makeCache(budgetBytes: oneFile * 3 / 2)
		await cache.store(result(), trackId: 1, preferLRCLIB: true)
		await cache.store(result(), trackId: 2, preferLRCLIB: true)

		XCTAssertEqual(temporary.fileNames(), ["2-lyrics.json"], "the older entry is the one to go")
	}

	func testLeastRecentlyUsedGoesFirst() async {
		// Three files of 2000 bytes against a 4000-byte budget, trimmed to 3200: two
		// of them have to go, oldest first.
		let cache = temporary.makeCache(budgetBytes: 4000)
		let now = Date()
		temporary.writeRawFile(trackId: 10, size: 2000, lastUsed: now.addingTimeInterval(-300))
		temporary.writeRawFile(trackId: 11, size: 2000, lastUsed: now.addingTimeInterval(-200))
		temporary.writeRawFile(trackId: 12, size: 2000, lastUsed: now.addingTimeInterval(-100))

		let removed = await cache.prune(now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), ["10-lyrics.json", "11-lyrics.json"])
		XCTAssertEqual(temporary.fileNames(), ["12-lyrics.json"])
	}

	func testAnOldDocumentIsKeptBecauseLyricsDoNotExpire() async {
		// Only the size cap evicts: a document from over a year ago is still the answer.
		let cache = temporary.makeCache()
		let now = Date()
		temporary.writeRawFile(trackId: 30, size: 100, lastUsed: now.addingTimeInterval(-400 * 24 * 60 * 60))
		await cache.store(result(), trackId: 31, preferLRCLIB: true)

		let removed = await cache.prune(now: now)

		XCTAssertEqual(removed, [])
		XCTAssertEqual(temporary.fileNames(), ["30-lyrics.json", "31-lyrics.json"])
	}

	func testTheFolderAndItsDocumentsArePrivateToTheUser() async {
		let cache = temporary.makeCache()
		await cache.store(result(), trackId: 40, preferLRCLIB: true)

		let folder = try? FileManager.default.attributesOfItem(atPath: temporary.root.path)
		XCTAssertEqual((folder?[.posixPermissions] as? NSNumber)?.intValue, 0o700)
		let document = try? FileManager.default.attributesOfItem(atPath: temporary.fileURL("40-lyrics.json").path)
		XCTAssertEqual((document?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
	}

	func testALooseFolderIsTightenedOnTheNextWrite() async {
		// Attributing a folder at creation only touches a folder created there and then.
		try? FileManager.default.createDirectory(at: temporary.root, withIntermediateDirectories: true)
		try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.root.path)
		let cache = temporary.makeCache()

		await cache.store(result(), trackId: 41, preferLRCLIB: true)

		let folder = try? FileManager.default.attributesOfItem(atPath: temporary.root.path)
		XCTAssertEqual((folder?[.posixPermissions] as? NSNumber)?.intValue, 0o700)
	}

	func testReadingADocumentKeepsIt() async {
		let generous = temporary.makeCache()
		await generous.store(result(), trackId: 20, preferLRCLIB: true)
		await generous.store(result(), trackId: 21, preferLRCLIB: true)
		let now = Date()
		temporary.backdate("20-lyrics.json", to: now.addingTimeInterval(-300))
		temporary.backdate("21-lyrics.json", to: now.addingTimeInterval(-200))

		// The lookup touches 20, so 21 becomes the least recently used.
		guard case .hit = await generous.lookup(trackId: 20, preferLRCLIB: true) else {
			return XCTFail("expected a disk hit")
		}
		let budget = temporary.fileSize("20-lyrics.json") + temporary.fileSize("21-lyrics.json") - 1
		let tight = temporary.makeCache(budgetBytes: budget)

		let removed = await tight.prune(now: now)

		XCTAssertEqual(removed.map(\.lastPathComponent), ["21-lyrics.json"])
		XCTAssertEqual(temporary.fileNames(), ["20-lyrics.json"], "reading a document is what keeps it")
	}

	// MARK: - Location

	func testTheCacheLivesInTheCachesDirectory() {
		let path = LyricsDiskCache.directory.standardizedFileURL.path
		let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].standardizedFileURL.path

		XCTAssertEqual(path, caches + "/TidalSwift/lyrics")
	}
}
