//
//  Player.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 21.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import AVFoundation
import CoreMedia
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
	// Incremented on every item change, so outdated async loads can be discarded.
	private var itemLoadID = 0
	private var itemStatusObservation: NSKeyValueObservation?
	private var itemTracksObservation: NSKeyValueObservation?


	private(set) var nextAudioQuality: AudioQuality
	private(set) var preferDolbyAtmos: Bool

	init(session: Session, audioQuality: AudioQuality, preferDolbyAtmos: Bool = false, autoplayAfterAddNow: Bool = true) {
		self.session = session
		self.nextAudioQuality = audioQuality
		self.preferDolbyAtmos = preferDolbyAtmos
		self.autoplayAfterAddNow = autoplayAfterAddNow

		PlaybackCache.pruneIfNeeded()

		timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: nil) { [weak self] _ in
			if let self {
				Task { @MainActor in
					self.playbackInfo.fraction = CGFloat(self.fraction())
					self.playbackInfo.playbackTimeInfo = self.playbackTimeInfo()
					self.playbackInfo.playbackPosition = self.currentPlaybackPosition()
				}
			}
		}

		observeVolume()
		observeShuffle()
	}

	// MARK: Prefetching

	/// Lazy because its closures read this player's live settings.
	private lazy var prefetcher = PlaybackPrefetcher.make(
		for: session,
		qualityProvider: { [weak self] in self?.nextAudioQuality ?? .high },
		preferDolbyAtmosProvider: { [weak self] in self?.preferDolbyAtmos ?? false }
	) { [weak self] _ in
		self?.shouldPrefetch() ?? false
	}

	private func shouldPrefetch() -> Bool {
		PlaybackRoutingPolicy.usesHLS(sessionHasDesktopPlaybackAccess: session.hasDesktopPlaybackAccess)
	}

	private func prefetchUpcoming() {
		prefetcher.queueChanged(queue: queueInfo.queue.map(\.track), currentIndex: queueInfo.currentIndex)
	}

	func stopPrefetching() {
		prefetcher.stop()
	}

	@MainActor
	deinit {
		if let token = timeObserverToken {
			avPlayer.removeTimeObserver(token)
			timeObserverToken = nil
		}
	}

	// MARK: Observers

	/// `withObservationTracking` fires `onChange` once only, so each observer re-arms itself.
	private func observeVolume() {
		withObservationTracking {
			_ = playbackInfo.volume
		} onChange: { [weak self] in
			Task { @MainActor in
				guard let self else { return }
				self.setVolume(to: self.playbackInfo.volume)
				self.observeVolume()
			}
		}
	}

	private func observeShuffle() {
		withObservationTracking {
			_ = playbackInfo.shuffle
		} onChange: { [weak self] in
			Task { @MainActor in
				guard let self else { return }
				self.shuffle(enabled: self.playbackInfo.shuffle)
				self.observeShuffle()
			}
		}
	}

	// MARK: Settings

	func setAudioQuality(to audioQuality: AudioQuality) {
		nextAudioQuality = audioQuality
	}

	func setPreferDolbyAtmos(to preferDolbyAtmos: Bool) {
		self.preferDolbyAtmos = preferDolbyAtmos
	}

	// MARK: Playback Control

	func play() {
		if !queueInfo.queue.isEmpty {
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
		if avPlayer.currentTime().seconds < 3 && queueInfo.currentIndex > 0 {
			prefetcher.trackSkipped()
		}
		previousTrack(resumeAfterSet: playbackInfo.playing)
	}

	private func previousTrack(resumeAfterSet: Bool) {
		guard !queueInfo.queue.isEmpty else { return }
		if avPlayer.currentTime().seconds >= 3 || queueInfo.currentIndex == 0 {
			avPlayer.seek(to: CMTime(seconds: 0, preferredTimescale: 1))
			if queueInfo.currentIndex == 0 && !queueInfo.queue[queueInfo.currentIndex].track.streamReady {
				print("Not possible to stream \(queueInfo.queue[queueInfo.currentIndex].track.title)")
				pause()
				advance(resumeAfterSet: resumeAfterSet)
			}
			return
		}

		queueInfo.currentIndex -= 1
		let track = queueInfo.queue[queueInfo.currentIndex].track
		if track.streamReady {
			avSetItem(from: track, resumeAfterSet: playbackInfo.pauseAfter ? false : resumeAfterSet)
		} else {
			print("Not possible to stream \(track.title)")
			previousTrack(resumeAfterSet: resumeAfterSet)
		}
	}

	/// A user pressing next: counts towards the browsing guard that stops preparing early.
	func next() {
		prefetcher.trackSkipped()
		advance(resumeAfterSet: playbackInfo.playing)
	}

	/// Moves on without counting as a manual skip (auto-advance, unplayable tracks).
	private func advance(resumeAfterSet: Bool, visited: Int = 0) {
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
			avSetItem(from: queueInfo.queue[queueInfo.currentIndex].track, resumeAfterSet: playbackInfo.pauseAfter ? false : resumeAfterSet)
		} else {
			let track = queueInfo.queue[queueInfo.currentIndex].track
			print("[PLAYBACK] next(): skipping non-streamable track - title: \(track.title), id: \(track.id), streamReady: \(track.streamReady), isUnavailable: \(track.isUnavailable), currentIndex: \(queueInfo.currentIndex), queueCount: \(queueInfo.queue.count)")
			failedItems += 1
			advance(resumeAfterSet: resumeAfterSet, visited: visited + 1)
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
		prefetchUpcoming()
	}

	func seek(to percentage: Double) {
		guard let currentItem = avPlayer.currentItem else {
			return
		}
		let seconds = percentage * currentItem.duration.seconds
		// A timescale of 1 rounds sub-second targets to whole seconds, dropping a tapped
		// lyric line early; seek at media resolution so the target is preserved.
		avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
	}

	// MARK: Stream Loading

	private func avSetItem(from track: Track, resumeAfterSet: Bool? = nil) {
		itemLoadID += 1
		let loadID = itemLoadID
		prefetchUpcoming()
		Task {
			await avSetItemAsync(from: track, loadID: loadID, resumeAfterSet: resumeAfterSet)
		}
	}

	private func avSetItemAsync(from track: Track, loadID: Int, resumeAfterSet: Bool? = nil) async {
		// A newer request can arrive while this one is in flight; discard the stale load.
		guard loadID == itemLoadID else {
			return
		}
		let shouldResume = resumeAfterSet ?? playbackInfo.playing
		pause()

		if track.isUnavailable {
			print("[PLAYBACK] avSetItem(): track unavailable - title: \(track.title), id: \(track.id), streamReady: \(track.streamReady), audioModes: \(String(describing: track.audioModes)), failedItems: \(failedItems), queueCount: \(queueInfo.queue.count)")
			skipFailedItem(resumeAfterSet: shouldResume)
			return
		}

		guard let url = await resolveStreamURL(for: track, loadID: loadID, resumeAfterSet: shouldResume) else {
			return
		}
		failedItems = 0
		playbackInfo.failedTrackIds.remove(track.id)

		let item = AVPlayerItem(url: url)
		installCurrentItem(item)
		playbackInfo.playbackPosition = 0
		fillHLSStreamSampleRate(from: item, loadID: loadID)

		if shouldResume {
			play()
		}
	}

	/// Fills the sample rate the player reports for a streamed HLS track, which the playlist
	/// itself cannot supply, so a streamed track reads like a cached one. Only the track's
	/// own resolved stream is touched, and only while it still describes this load.
	///
	/// A Tidal playlist's `item.asset.tracks` stays empty; the rate arrives with the item's
	/// own `tracks` once the item is installed and loading begins, so observe them rather
	/// than reading once.
	private func fillHLSStreamSampleRate(from item: AVPlayerItem, loadID: Int) {
		guard let stream = playbackInfo.resolvedStream, stream.isHLS, stream.sampleRate == nil else {
			return
		}
		let trackId = stream.trackId
		itemTracksObservation?.invalidate()
		itemTracksObservation = item.observe(\.tracks, options: [.initial, .new]) { [weak self] item, _ in
			Task { @MainActor [weak self] in
				guard let self, loadID == self.itemLoadID, self.playbackInfo.resolvedStream?.trackId == trackId else { return }
				guard let rate = await Self.sampleRate(of: item) else { return }
				guard loadID == self.itemLoadID, self.playbackInfo.resolvedStream?.trackId == trackId else { return }
				self.playbackInfo.resolvedStream?.sampleRate = rate
				self.itemTracksObservation?.invalidate()
				self.itemTracksObservation = nil
			}
		}
	}

	/// The first audio sample rate the item's own tracks report, or nil while it reports none.
	private static func sampleRate(of item: AVPlayerItem) async -> Int? {
		for itemTrack in item.tracks {
			guard let assetTrack = itemTrack.assetTrack, assetTrack.mediaType == .audio else { continue }
			guard let descriptions = try? await assetTrack.load(.formatDescriptions) else { continue }
			for description in descriptions {
				guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
				let rate = Int(basic.mSampleRate)
				if rate > 0 { return rate }
			}
		}
		return nil
	}

	/// Resolves the URL that plays `track` — the offline copy first, then the policy's
	/// online routes — and publishes the resolved stream. A rendition fetch can suspend
	/// for a download, so the stale-load check repeats in every publishing path.
	private func resolveStreamURL(for track: Track, loadID: Int, resumeAfterSet: Bool) async -> URL? {
		// The cache write behind an online play prunes under this: the prefetch window, the
		// current track and the queue, so a play never evicts what is about to play.
		let protection = prefetcher.cacheProtection()
		if let offlineStream = await session.helpers.offline.stream(for: track, ceiling: nextAudioQuality) {
			guard loadID == itemLoadID else {
				return nil
			}
			print("Play \(track.title) from offline URL: \(offlineStream.url)")
			print("[PLAYBACK] avSetItem(): resolved URL - title: \(track.title), quality: \(offlineStream.quality?.rawValue ?? nextAudioQuality.rawValue), source: offline")
			// The badge reads the tier the file holds, not the ceiling: a 24-bit offline file on a
			// track advertised LOSSLESS must not read 16-bit.
			let rung: HLSRung? = offlineStream.isDolbyAtmos
				? .dolbyAtmos
				: offlineStream.quality.map(HLSRung.stereo)
			playbackInfo.resolvedStream = ResolvedStream(
				trackId: track.id,
				quality: offlineStream.quality ?? nextAudioQuality,
				isDolbyAtmos: offlineStream.isDolbyAtmos,
				rung: rung
			)
			return offlineStream.url
		}

		if let stream = await session.playableStream(
			for: track,
			quality: nextAudioQuality,
			preferDolbyAtmos: preferDolbyAtmos,
			protecting: protection.protecting,
			queueTrackIds: protection.queueTrackIds
		) {
			guard loadID == itemLoadID else {
				return nil
			}
			// A stream URL carries a signed token in its path and query, so only the host is logged.
			print("Play \(track.title) from online URL on \(stream.url.host ?? "a local file")")
			print("[PLAYBACK] avSetItem(): resolved URL - title: \(track.title), quality: \(stream.quality), source: online")
			let rung: HLSRung? = stream.isHLS
				? (stream.isDolbyAtmos ? .dolbyAtmos : .stereo(stream.quality))
				: nil
			playbackInfo.resolvedStream = ResolvedStream(
				trackId: track.id,
				quality: stream.quality,
				isDolbyAtmos: stream.isDolbyAtmos,
				sampleRate: stream.sampleRate,
				isHLS: stream.isHLS,
				rung: rung
			)
			return stream.url
		}

		guard loadID == itemLoadID else {
			return nil
		}
		print("No URL so skipping \(track.title)")
		print("[PLAYBACK] avSetItem(): no URL - title: \(track.title), id: \(track.id), failedItems: \(failedItems), queueCount: \(queueInfo.queue.count)")
		playbackInfo.failedTrackIds.insert(track.id)
		skipFailedItem(resumeAfterSet: resumeAfterSet)
		return nil
	}

	private func skipFailedItem(resumeAfterSet: Bool) {
		failedItems += 1
		if failedItems == queueInfo.queue.count {
			print("[PLAYBACK] all tracks in queue failed to play")
			pause()
			seek(to: 0)
		} else {
			advance(resumeAfterSet: resumeAfterSet)
		}
	}

	/// A failed or stalled item posts no end notification, so its status is observed
	/// directly; the identity check drops a late failure for an item since replaced.
	private func installCurrentItem(_ item: AVPlayerItem) {
		NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem)
		NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: avPlayer.currentItem)
		NotificationCenter.default.addObserver(self, selector: #selector(self.playerDidFinishPlaying(sender:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item)
		NotificationCenter.default.addObserver(self, selector: #selector(self.playerItemFailedToPlayToEndTime(sender:)), name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: item)
		itemStatusObservation?.invalidate()
		itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
			guard item.status == .failed else { return }
			let description = item.error.map { $0.localizedDescription }
			let itemID = ObjectIdentifier(item)
			Task { @MainActor [weak self] in
				guard let self, let current = self.avPlayer.currentItem, ObjectIdentifier(current) == itemID else { return }
				self.playerItemFailed(reason: "item status .failed", errorDescription: description)
			}
		}
		avPlayer.replaceCurrentItem(with: item)
	}

	@objc func playerDidFinishPlaying(sender: Notification) {
		advance(resumeAfterSet: playbackInfo.playing)
	}

	/// The item failed after playback started. `AVPlayerItemDidPlayToEndTime` is not
	/// posted then, so without this the queue would sit on an item that never plays.
	@objc func playerItemFailedToPlayToEndTime(sender: Notification) {
		guard let item = sender.object as? AVPlayerItem, item === avPlayer.currentItem else { return }
		let description = (sender.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
			.map { $0.localizedDescription }
		playerItemFailed(reason: "AVPlayerItemFailedToPlayToEndTime", errorDescription: description)
	}

	private func playerItemFailed(reason: String, errorDescription: String?) {
		let track = queueInfo.currentItem?.track
		print("[PLAYBACK] item failed - title: \(track?.title ?? "?"), id: \(track.map { String($0.id) } ?? "?"), reason: \(reason), error: \(errorDescription ?? "none"), failedItems: \(failedItems), queueCount: \(queueInfo.queue.count)")
		if let track {
			playbackInfo.failedTrackIds.insert(track.id)
		}
		failedItems += 1
		if failedItems >= queueInfo.queue.count {
			print("[PLAYBACK] all tracks in queue failed to play")
			pause()
			seek(to: 0)
		} else {
			advance(resumeAfterSet: playbackInfo.playing)
		}
	}

	// MARK: Queue

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
	}

	private func addNext(tracks: [Track], source: QueueSource?) {
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
		prefetchUpcoming()
	}

	private func addLast(tracks: [Track], source: QueueSource?) {
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
		prefetchUpcoming()
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
		// Removing the current track can leave currentIndex past the new end; clamp it so
		// the queue lookup below can't trap.
		if queueInfo.currentIndex >= queueInfo.queue.count {
			queueInfo.currentIndex = max(0, queueInfo.queue.count - 1)
		}
		queueInfo.assignQueueIndices()
		prefetchUpcoming()

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
			itemLoadID += 1
			avPlayer.pause()
			playbackInfo.playing = false
			queueInfo.currentIndex = 0
			avPlayer.replaceCurrentItem(with: nil)
			queueInfo.queue.removeAll()
			queueInfo.nonShuffledQueue.removeAll()
			queueInfo.source = nil
		}
		prefetchUpcoming()
	}

	func queueCount() -> Int {
		queueInfo.queue.count
	}

	// MARK: Time

	func fraction() -> Double {
		guard let totalTime = avPlayer.currentItem?.duration.seconds else {
			return 0
		}
		guard !totalTime.isNaN else {
			return 0
		}

		let r = avPlayer.currentTime().seconds / totalTime

		return r
	}

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

	// MARK: Volume

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

	// MARK: Quality Badge

	func currentQualityString() -> String {
		guard !queueInfo.queue.isEmpty else {
			return ""
		}
		let track = queueInfo.queue[queueInfo.currentIndex].track
		// Describe the stream that plays, not what the track could offer: Tidal reports
		// Atmos tracks as `audioQuality: .low`, and such a track plays stereo when the
		// preference is off. Resolution is async, so a stored stream for another track
		// means this one has not resolved yet — say nothing rather than mislabel it.
		guard let stream = playbackInfo.resolvedStream, stream.trackId == track.id else {
			return ""
		}
		if let rung = stream.rung {
			return HLSStreaming.badge(for: rung, sampleRate: stream.sampleRate)
		}
		if stream.isDolbyAtmos {
			return "Dolby Atmos"
		}
		guard let quality = track.audioQuality else {
			return ""
		}

		return qualityToString(quality: stream.quality.servedByDirectStream(advertised: quality))
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
			// Never shown: `currentQualityString` clamps `.max` to `.high` above.
			return "24-bit 192kHz"
		}
	}
}
