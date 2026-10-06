//
//  OfflineCancellationTests.swift
//  TidalSwiftLibTests
//

import XCTest
@testable import TidalSwiftLib

/// "Remove All Offline Content" cancels the sync that is running. Nothing checked for
/// that, so the pass walked the remaining tracks, resolved each one over the network
/// and reported every cancellation as a failed download — a flash of error toasts on
/// a deliberate action. Everything runs against the temporary library root from
/// `TemporaryOfflineLibrary`, never the real folder or the network.
@MainActor
final class OfflineCancellationTests: XCTestCase {
	private nonisolated let offlineLibrary = TemporaryOfflineLibrary(label: "OfflineCancellation")

	override func tearDown() {
		displayErrorHandler = nil
		offlineLibrary.remove()
		super.tearDown()
	}

	func testCancelledSyncStopsWithoutReportingFailures() async throws {
		let firstTrackId = 644_000_001
		let secondTrackId = 644_000_002
		let fixture = try silentFlacFixture()

		let resolved = Counter()
		let errors = Counter()
		displayErrorHandler = { _, _ in errors.value += 1 }

		let session = offlineLibrary.makeSession()
		let offline = session.helpers.offline
		offline.resolveOfflineStream = { track in
			resolved.value += 1
			// The deliberate removal, from inside the running sync, on whichever track
			// the wanted set hands out first (it is a Set, so the order is not fixed).
			// Yielding lets the cancellation land before the loop looks for it, which is
			// what keeps this test off a race.
			if resolved.value == 1 {
				offline.removeAll()
				for _ in 0..<10 {
					await Task.yield()
				}
			}
			guard track.id == firstTrackId else { return nil }
			return AudioStream(url: fixture, pathExtension: "flac", isDolbyAtmos: false)
		}

		offline.setOfflineTracksForTesting([makeTrack(id: firstTrackId), makeTrack(id: secondTrackId)])
		await offline.awaitOngoingSync()

		XCTAssertEqual(resolved.value, 1, "a cancelled sync must stop instead of resolving every remaining track")
		XCTAssertEqual(errors.value, 0, "a cancelled sync must not report its remaining tracks as failures")
	}

	// MARK: - Helpers

	private final class Counter {
		var value = 0
	}

	private func silentFlacFixture() throws -> URL {
		try XCTUnwrap(Bundle.module.url(forResource: "silent", withExtension: "flac", subdirectory: "Fixtures"))
	}

	private func makeTrack(id: Int) -> Track {
		Track(
			id: id,
			title: "Cancel Test",
			duration: 180,
			replayGain: 0,
			peak: nil,
			allowStreaming: true,
			streamReady: true,
			streamStartDate: nil,
			premiumStreamingOnly: nil,
			trackNumber: 1,
			volumeNumber: 1,
			version: nil,
			popularity: 0,
			copyright: nil,
			description: nil,
			url: URL(string: "https://tidal.com/track/\(id)")!,
			isrc: nil,
			editable: false,
			explicit: false,
			audioQuality: .high,
			audioModes: [.stereo],
			artist: nil,
			artists: [],
			album: makeAlbum(id: id),
			mixes: nil,
			dateAdded: nil,
			index: nil,
			itemUuid: nil,
			bpm: nil,
			key: nil,
			keyScale: nil
		)
	}

	private func makeAlbum(id: Int) -> Album {
		Album(
			id: id,
			title: "Cancel Test",
			duration: nil,
			streamReady: nil,
			streamStartDate: nil,
			allowStreaming: nil,
			premiumStreamingOnly: nil,
			numberOfTracks: nil,
			numberOfVideos: nil,
			numberOfVolumes: nil,
			releaseDate: nil,
			copyright: nil,
			type: nil,
			version: nil,
			url: nil,
			cover: nil,
			videoCover: nil,
			explicit: false,
			upc: nil,
			popularity: nil,
			audioQuality: .high,
			audioModes: [.stereo],
			artist: nil,
			artists: nil
		)
	}
}
