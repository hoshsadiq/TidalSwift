//
//  Player.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 21.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
@preconcurrency import Combine
import AVFoundation
import TidalSwiftLib

class Player {
	let session: Session
	var autoplayAfterAddNow: Bool

	let avPlayer = AVPlayer()
	public let playbackInfo = PlaybackInfo()
	public let queueInfo = QueueInfo()

	private var timeObserverToken: Any?

	private var previousValue: Float = 1.0
	private var failedItems = 0

	private var volumeCancellable: AnyCancellable?
	private var shuffleCancellable: AnyCancellable?

	private var currentAudioQuality: AudioQuality
	private(set) var nextAudioQuality: AudioQuality

	init(session: Session, audioQuality: AudioQuality, autoplayAfterAddNow: Bool = true) {
		self.session = session
		self.currentAudioQuality = audioQuality
		self.nextAudioQuality = audioQuality
		self.autoplayAfterAddNow = autoplayAfterAddNow

		timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: nil) { [weak self] _ in
			if let self {
				Task { @MainActor in
					self.playbackInfo.fraction = CGFloat(self.fraction())
					self.playbackInfo.playbackTimeInfo = self.playbackTimeInfo()
					self.playbackInfo.playbackPosition = self.currentPlaybackPosition()
				}
			}
		}

		volumeCancellable = playbackInfo.$volume.receive(on: DispatchQueue.main).sink(receiveValue: setVolume(to:))
		shuffleCancellable = playbackInfo.$shuffle.receive(on: DispatchQueue.main).sink(receiveValue: shuffle(enabled:))
	}

	@MainActor
	deinit {
		if let token = timeObserverToken {
			avPlayer.removeTimeObserver(token)
			timeObserverToken = nil
		}
		volumeCancellable?.cancel()
		shuffleCancellable?.cancel()
	}

	func setAudioQuality(to audioQuality: AudioQuality) {
		nextAudioQuality = audioQuality
	}

	func play() {
		if !queueInfo.queue.isEmpty {
//			print("Play: \(playbackInfo.queue[playbackInfo.currentIndex].track.title)")
			avPlayer.play()
			playbackInfo.playing = true
			queueInfo.addToHistory(track: queueInfo.queue[queueInfo.currentIndex].track)
		}
	}

	func play(atIndex: Int) {
		if queueInfo.queue.count > atIndex {
			queueInfo.currentIndex = atIndex
			avSetItem(from: queueInfo.queue[queueInfo.currentIndex].track)
			play()
		}
	}

	func pause() {
		avPlayer.pause()
		playbackInfo.playing = false

	}

	func togglePlay() {
		if playbackInfo.playing {
			pause()
		} else {
			play()
		}
	}

	func stop() {
		pause()
		seek(to: 0)
	}

	func previous() {
		guard !queueInfo.queue.isEmpty else { return }
		if avPlayer.currentTime().seconds >= 3 || queueInfo.currentIndex == 0 {
			avPlayer.seek(to: CMTime(seconds: 0, preferredTimescale: 1))
			if queueInfo.currentIndex == 0 && !queueInfo.queue[queueInfo.currentIndex].track.streamReady {
				print("Not possible to stream \(queueInfo.queue[queueInfo.currentIndex].track.title)")
				pause()
				next()
			}
			return
		}

		queueInfo.currentIndex -= 1
		if queueInfo.queue[queueInfo.currentIndex].track.streamReady {
//			print("previous(): \(playbackInfo.currentIndex) - \(playbackInfo.queue.count)")
			avSetItem(from: queueInfo.queue[queueInfo.currentIndex].track)
//			print("previous() done")
		} else {
			print("Not possible to stream \(queueInfo.queue[queueInfo.currentIndex].track.title)")
			previous()
		}
	}

	func next() {
		next(resumeAfterSet: playbackInfo.playing)
	}

	private func next(resumeAfterSet: Bool, visited: Int = 0) {
		if playbackInfo.repeatState == .single {
			seek(to: 0)
			return
		}

		if visited >= 5 {
			print("[PLAYBACK] stopping after 5 consecutive failures")
			pause()
			seek(to: 0)
			return
		}

		if queueInfo.currentIndex >= queueInfo.queue.count - 1 {
//			print("next(): \(playbackInfo.currentIndex) Last - \(playbackInfo.queue.count)")
			if playbackInfo.repeatState == .all {
				queueInfo.currentIndex = 0
			} else {
				pause()
				seek(to: 0)
				return
			}
		} else {
			queueInfo.currentIndex += 1
		}
		if queueInfo.queue[queueInfo.currentIndex].track.streamReady {
//			print("next(): \(playbackInfo.currentIndex) - \(queueCount())")
			avSetItem(from: queueInfo.queue[queueInfo.currentIndex].track, resumeAfterSet: playbackInfo.pauseAfter ? false : resumeAfterSet)
		} else {
			let track = queueInfo.queue[queueInfo.currentIndex].track
			print("[PLAYBACK] next(): skipping non-streamable track - title: \(track.title), id: \(track.id), streamReady: \(track.streamReady), isUnavailable: \(track.isUnavailable), currentIndex: \(queueInfo.currentIndex), queueCount: \(queueInfo.queue.count)")
			failedItems += 1
			next(resumeAfterSet: resumeAfterSet, visited: visited + 1)
		}

		if playbackInfo.pauseAfter {
			pause()
		}
	}

	func shuffle(enabled: Bool) {
		if queueInfo.queue.isEmpty {
			return
		}
		failedItems = 0
		if enabled {
			queueInfo.nonShuffledQueue = queueInfo.queue
			queueInfo.queue = queueInfo.queue[0...queueInfo.currentIndex] +
				queueInfo.queue[queueInfo.currentIndex + 1..<queueInfo.queue.count].shuffled()
			queueInfo.assignQueueIndices()
		} else {
			if let i = queueInfo.nonShuffledQueue.firstIndex(where: { $0 == queueInfo.queue[queueInfo.currentIndex] }) {
				queueInfo.queue = queueInfo.nonShuffledQueue
				queueInfo.assignQueueIndices()
				queueInfo.currentIndex = i
			}
		}
	}

	func seek(to percentage: Double) {
		guard let currentItem = avPlayer.currentItem else {
			return
		}
		let seconds = percentage * currentItem.duration.seconds
		// A timescale of 1 rounds sub-second targets to whole seconds, which
		// drops a tapped lyric line up to half a second early. Seek at media
		// resolution so the target is preserved.
		avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
	}

	private func avSetItem(from track: Track, resumeAfterSet: Bool? = nil) {
		Task {
			await avSetItemAsync(from: track, resumeAfterSet: resumeAfterSet)
		}
	}

	private func avSetItemAsync(from track: Track, resumeAfterSet: Bool? = nil) async {
//		print("avSetItem(): \(track.title)")
		let shouldResume = resumeAfterSet ?? playbackInfo.playing
		pause()

		func skip() {
			failedItems += 1
			if failedItems == queueInfo.queue.count {
				print("[PLAYBACK] all tracks in queue failed to play")
				pause()
				seek(to: 0)
			} else {
				next(resumeAfterSet: shouldResume)
			}
		}

		if track.isUnavailable {
			print("[PLAYBACK] avSetItem(): track unavailable - title: \(track.title), id: \(track.id), streamReady: \(track.streamReady), audioModes: \(String(describing: track.audioModes)), failedItems: \(failedItems), queueCount: \(queueInfo.queue.count)")
			skip()
			return
		}

		let url: URL
		if let offlineUrl = await session.helpers.offline.url(for: track) {
			print("Play \(track.title) from offline URL: \(offlineUrl)")
			print("[PLAYBACK] avSetItem(): resolved URL - title: \(track.title), quality: \(nextAudioQuality), source: offline")
			url = offlineUrl
			currentAudioQuality = nextAudioQuality
		} else if let resolved = await session.bestAudioUrl(trackId: track.id, preferredQuality: nextAudioQuality) {
			print("Play \(track.title) from online URL: \(resolved.url)")
			print("[PLAYBACK] avSetItem(): resolved URL - title: \(track.title), quality: \(resolved.quality), source: online")
			url = resolved.url
			currentAudioQuality = resolved.quality
		} else {
			print("No URL so skipping \(track.title)")
			print("[PLAYBACK] avSetItem(): no URL - title: \(track.title), id: \(track.id), failedItems: \(failedItems), queueCount: \(queueInfo.queue.count)")
			playbackInfo.failedTrackIds.insert(track.id)
			skip()
			return
		}
		failedItems = 0
		playbackInfo.failedTrackIds.remove(track.id)

		NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem)

		let item = AVPlayerItem(url: url)
		NotificationCenter.default.addObserver(self, selector: #selector(self.playerDidFinishPlaying(sender:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item)
		avPlayer.replaceCurrentItem(with: item)
		// The periodic observer only refreshes once a second; reset eagerly so a
		// new track can't briefly highlight a line at the previous track's time.
		playbackInfo.playbackPosition = 0

		if shouldResume {
//			print("Was playing...")
			play()
		}
	}

	@objc func playerDidFinishPlaying(sender: Notification) {
//		print("Song finished playing")
		next()
	}

	func add(playlists: [Playlist], _ when: When, source: QueueSource? = nil) {
		playlists.forEach { playlist in
			add(playlist: playlist, when, source: source)
		}
	}

	func add(playlist: Playlist, _ when: When, source: QueueSource? = nil) {
		Task {
			let apiTracks = await session.playlistTracks(playlistId: playlist.uuid)
			let offlineTracks = await session.helpers.offline.getTracks(for: playlist)
			if let tracks = apiTracks ?? offlineTracks {
				add(tracks: tracks, when, source: source)
			}
		}
	}

	func add(albums: [Album], _ when: When, source: QueueSource? = nil) {
		albums.forEach { album in
			add(album: album, when, source: source)
		}
	}

	func add(album: Album, _ when: When, source: QueueSource? = nil) {
		Task {
			let apiTracks = await session.albumTracks(albumId: album.id)
			let offlineTracks = await session.helpers.offline.getTracks(for: album)
			if let tracks = apiTracks ?? offlineTracks {
				add(tracks: tracks, when, source: source)
			} else if when == .now {
				clearQueue()
			}
		}
	}

	func add(artist: Artist, _ when: When, source: QueueSource? = nil) {
		Task {
			if let tracks = await session.artistTopTracks(artistId: artist.id) {
				add(tracks: tracks, when, source: source)
			}
		}
	}

	func add(track: Track, _ when: When, source: QueueSource? = nil) {
		add(tracks: [track], when, source: source)
	}

	enum When {
		case now
		case next
		case last
	}

	func add(tracks: [Track], _ when: When, playAt index: Int = 0, source: QueueSource? = nil) {
		failedItems = 0
		let safeIndex = min(max(index, 0), tracks.count)
		let unavailableCount = tracks[0..<safeIndex].filter(\.isUnavailable).count
		let newIndex = safeIndex - unavailableCount
		print("New Index: \(newIndex), index: \(index), \(unavailableCount)")

		let tracks = tracks.filter { !$0.isUnavailable }
		if when == .now {
			addNow(tracks: tracks, playAt: newIndex, source: source)
			play(atIndex: newIndex)
		} else if when == .next {
			addNext(tracks: tracks, source: source)
		} else {
			addLast(tracks: tracks, source: source)
		}
	}

	// playAt is only important when in Shuffle, so only items after the one at the index are shuffled.
	private func addNow(tracks: [Track], playAt index: Int, source: QueueSource?) {
//		print("addNow(): \(tracks.count)")
		if tracks.isEmpty {
			return
		}

		let wasPlaying = playbackInfo.playing
		clearQueue()
		if playbackInfo.shuffle {
			let safeIndex = min(max(index, 0), tracks.count - 1)
			queueInfo.nonShuffledQueue = tracks.wrapped()
			addLast(tracks: Array(tracks[0...safeIndex]), source: source)
			if safeIndex + 1 < tracks.count {
				addLast(tracks: tracks[safeIndex + 1..<tracks.count].shuffled(), source: source)
			}
		} else {
			addLast(tracks: tracks, source: source)
		}
		if wasPlaying {
			play()
		}
//		print("addNow() finished. Items in Queue: \(playbackInfo.queue.count)")
	}

	private func addNext(tracks: [Track], source: QueueSource?) {
//		print("addNext(): \(tracks.count)")
		if tracks.isEmpty {
			return
		}
		queueInfo.nonShuffledQueue.insert(contentsOf: tracks.wrapped(), at: queueInfo.currentIndex)
		let newQueueItems = tracks.wrapped()
		if queueInfo.queue.isEmpty {
			queueInfo.source = source
			queueInfo.queue.insert(contentsOf: newQueueItems, at: queueInfo.currentIndex)
			avSetItem(from: queueInfo.queue[0].track)
		} else {
			queueInfo.queue.insert(contentsOf: newQueueItems, at: queueInfo.currentIndex + 1)
		}
		queueInfo.assignQueueIndices()
//		print("addNext() finished. Items in Queue: \(queueInfo.queue.count)")
	}

	private func addLast(tracks: [Track], source: QueueSource?) {
//		print("addLast(): \(tracks.count)")
		if tracks.isEmpty {
			return
		}
		let wasEmtpy = queueInfo.queue.isEmpty

		if !playbackInfo.shuffle {
			queueInfo.nonShuffledQueue.append(contentsOf: tracks.wrapped())
		}

		let newQueueItems = tracks.wrapped()
		queueInfo.queue.append(contentsOf: newQueueItems)
		queueInfo.assignQueueIndices()
		if wasEmtpy {
			queueInfo.source = source
			avSetItem(from: queueInfo.queue[queueInfo.currentIndex].track)
		}
//		print("addLast() finished. Items in Queue: \(queueInfo.queue.count)")
	}

	func removeTrack(atIndex: Int) {
		guard queueInfo.queue.indices.contains(atIndex) else { return }
		failedItems = 0
		let removedCurrent = atIndex == queueInfo.currentIndex

		if playbackInfo.shuffle {
			guard let nonShuffledIndex = queueInfo.nonShuffledQueue.firstIndex(of: queueInfo.queue[atIndex]) else {
				print("ERROR - Player.removeTrack(): queueInfo.nonShuffledQueue.firstIndex is nil")
				return
			}
			queueInfo.nonShuffledQueue.remove(at: nonShuffledIndex)
		} else if queueInfo.nonShuffledQueue.indices.contains(atIndex) {
			queueInfo.nonShuffledQueue.remove(at: atIndex)
		}
		queueInfo.queue.remove(at: atIndex)

		if atIndex < queueInfo.currentIndex {
			queueInfo.currentIndex -= 1
		}
		// Removing the current (possibly last) track can leave currentIndex at or
		// past the new end; clamp so the queue lookup below can't trap.
		if queueInfo.currentIndex >= queueInfo.queue.count {
			queueInfo.currentIndex = max(0, queueInfo.queue.count - 1)
		}
		queueInfo.assignQueueIndices()

		if removedCurrent {
			if !queueInfo.queue.isEmpty {
				avSetItem(from: queueInfo.queue[queueInfo.currentIndex].track)
			} else {
				avPlayer.replaceCurrentItem(with: nil)
				playbackInfo.playing = false
			}
		}
	}

	func clearQueue(leavingCurrent: Bool = false) {
		failedItems = 0
		if leavingCurrent {
			guard !queueInfo.queue.isEmpty else { return }
			let current = min(max(queueInfo.currentIndex, 0), queueInfo.queue.count - 1)
			queueInfo.queue.removeFirst(current)
			queueInfo.queue.removeLast(queueInfo.queue.count - 1)
			queueInfo.currentIndex = 0
			queueInfo.nonShuffledQueue = queueInfo.queue
			queueInfo.assignQueueIndices()
		} else {
			avPlayer.pause()
			playbackInfo.playing = false
			queueInfo.currentIndex = 0
			avPlayer.replaceCurrentItem(with: nil)
			queueInfo.queue.removeAll()
			queueInfo.nonShuffledQueue.removeAll()
			queueInfo.source = nil
		}
	}

	func queueCount() -> Int {
		queueInfo.queue.count
	}

	func fraction() -> Double {
		guard let totalTime = avPlayer.currentItem?.duration.seconds else {
			return 0
		}
		guard !totalTime.isNaN else {
			return 0
		}

		let r = avPlayer.currentTime().seconds / totalTime
//		print("fraction(): r: \(r), currentTime: \(avPlayer.currentTime().seconds), totalTime: \(totalTime)")

		return r
	}

	/// Current playback position in seconds, or 0 while no item is loaded or the
	/// player reports a non-finite time.
	private func currentPlaybackPosition() -> Double {
		let seconds = avPlayer.currentTime().seconds
		return seconds.isFinite ? seconds : 0
	}

	func playbackTimeInfo() -> String {
		guard let totalTime = avPlayer.currentItem?.duration.seconds else {
			return ""
		}
		guard !totalTime.isNaN else {
			return ""
		}

		let currentTimeString = secondsToHoursMinutesSecondsString(seconds: Int(avPlayer.currentTime().seconds))
		let totalTimeString = secondsToHoursMinutesSecondsString(seconds: Int(totalTime))
		return "\(currentTimeString) / \(totalTimeString)"
	}

	func setVolume(to volume: Float) {
		avPlayer.volume = volume
	}

	func increaseVolume() {
		var newVolume = playbackInfo.volume + 0.1
		if newVolume > 1 {
			newVolume = 1
		}
		playbackInfo.volume = newVolume
	}

	func decreaseVolume() {
		var newVolume = playbackInfo.volume - 0.1
		if newVolume < 0 {
			newVolume = 0
		}
		playbackInfo.volume = newVolume
	}

	func toggleMute() {
		if playbackInfo.volume == 0 {
			playbackInfo.volume = previousValue
		} else {
			previousValue = playbackInfo.volume
			playbackInfo.volume = 0
		}
	}

	func currentQualityString() -> String {
		guard !queueInfo.queue.isEmpty else {
			return ""
		}
		let track = queueInfo.queue[queueInfo.currentIndex].track
		// Tidal reports Atmos tracks as `audioQuality: .low`, which would otherwise
		// be shown as a bitrate; the stream itself is always Dolby Atmos.
		if track.audioModes?.contains(.dolbyAtmos) ?? false {
			return "Dolby Atmos"
		}
		guard let quality = track.audioQuality else {
			return ""
		}

		var chosenQuality = currentAudioQuality
//		print("\(chosenQuality) \(quality)")

		if chosenQuality == .max && quality != .max {
			chosenQuality = .high
		}
		if chosenQuality == .high && (quality == .medium || quality == .low) {
			chosenQuality = .medium
		}
		if chosenQuality == .medium && quality == .low {
			chosenQuality = .low
		}

		return qualityToString(quality: chosenQuality)
	}

	private func qualityToString(quality: AudioQuality) -> String {
		switch quality {
		case .low:
			return "96 kbps"
		case .medium:
			return "320 kbps"
		case .high:
			return "16-bit 44.1kHz"
		case .max:
			return "24-bit 192kHz"
		}
	}
}
