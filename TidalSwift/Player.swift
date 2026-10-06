//
//  Player.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 21.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
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
	// Incremented on every item change, so outdated async loads can be discarded
	private var itemLoadID = 0
	// KVO on the current item's `status`, invalidated when the next item is installed.
	private var itemStatusObservation: NSKeyValueObservation?


	private(set) var nextAudioQuality: AudioQuality
	private(set) var preferDolbyAtmos: Bool
	/// Whether the stream that plays is the locally decrypted hi-res rendition, and
	/// its bit depth, read from the file. Plain, not observable, but written just
	/// before `playbackInfo.resolvedStream`, so the view that re-renders on that
	/// write reads the new value.
	private(set) var isPlayingHiResStereo = false
	private(set) var currentHiResBitDepth: Int?

	init(session: Session, audioQuality: AudioQuality, preferDolbyAtmos: Bool = false, autoplayAfterAddNow: Bool = true) {
		self.session = session
		self.nextAudioQuality = audioQuality
		self.preferDolbyAtmos = preferDolbyAtmos
		self.autoplayAfterAddNow = autoplayAfterAddNow

		// A cache that grew while the app was closed is bounded before it is read.
		HiResStreaming.pruneCache()

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

	/// Prepares the tracks after the current one in the queue so they start instantly.
	/// Lazy because its closures read this player's live settings.
	private lazy var prefetcher = HiResStreaming.makePrefetcher(
		for: session,
		qualityProvider: { [weak self] in self?.nextAudioQuality ?? .high }
	) { [weak self] track in
		self?.shouldPrefetch(track) ?? false
	}

	/// Whether a local-file route is the one that plays first for `track`, which is
	/// when preparing it in advance is worth the bandwidth: the decrypted FLAC route at
	/// `Max`/`Lossless`, or the DASH route at `High`/`Low`. The direct-stream route
	/// streams, so nothing is prepared for it.
	private func shouldPrefetch(_ track: Track) -> Bool {
		HiResStreamingPolicy.usesLocalFile(
			sessionHasHiResStereoAccess: session.hasHiResStereoAccess,
			preferDolbyAtmos: track.hasDolbyAtmos && preferDolbyAtmos,
			trackHasStereo: track.hasStereo,
			trackHasDolbyAtmos: track.hasDolbyAtmos,
			quality: nextAudioQuality
		)
	}

	private func prefetchUpcoming() {
		prefetcher.queueChanged(queue: queueInfo.queue.map(\.track), currentIndex: queueInfo.currentIndex)
	}

	/// Stops preparing upcoming tracks. Called on quit so a teardown does not leave a
	/// download in flight.
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

	/// Applies a volume or shuffle change to the underlying player. Each observer
	/// re-arms itself: `withObservationTracking` fires `onChange` only once, before the
	/// new value is written, so the handler runs on the next main-actor turn with the
	/// new value already in place.
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
		// Restarting the current track (or already at the first) is not a skip.
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

	/// A user pressing next: counts towards the browsing guard that stops preparing
	/// tracks in advance.
	func next() {
		prefetcher.trackSkipped()
		advance(resumeAfterSet: playbackInfo.playing)
	}

	/// Moves to the next track without counting as a manual skip (auto-advance and
	/// skipping past unplayable tracks).
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
		// A timescale of 1 rounds sub-second targets to whole seconds, which
		// drops a tapped lyric line up to half a second early. Seek at media
		// resolution so the target is preserved.
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
		// Loading is async, so a newer request can arrive while this one is in flight.
		// Discard the stale load instead of replacing the newer item's playback.
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
		// The periodic observer only refreshes once a second; reset eagerly so a
		// new track can't briefly highlight a line at the previous track's time.
		playbackInfo.playbackPosition = 0

		if shouldResume {
			play()
		}
	}

	/// Resolves the URL that plays `track` — the offline copy first, then the policy's
	/// online routes — and publishes the resolved stream. Returns nil when the load is
	/// stale or no route produced a stream, and skips the track in the latter case.
	///
	/// A rendition fetch can suspend for the whole download, so the stale-load check at
	/// the top has to repeat in each path that publishes a result.
	private func resolveStreamURL(for track: Track, loadID: Int, resumeAfterSet: Bool) async -> URL? {
		isPlayingHiResStereo = false

		if let offlineStream = await session.helpers.offline.stream(for: track) {
			guard loadID == itemLoadID else {
				return nil
			}
			print("Play \(track.title) from offline URL: \(offlineStream.url)")
			print("[PLAYBACK] avSetItem(): resolved URL - title: \(track.title), quality: \(nextAudioQuality), source: offline")
			playbackInfo.resolvedStream = ResolvedStream(
				trackId: track.id,
				quality: nextAudioQuality,
				isDolbyAtmos: offlineStream.isDolbyAtmos
			)
			return offlineStream.url
		}

		if let stream = await session.playableStream(
			for: track,
			quality: nextAudioQuality,
			preferDolbyAtmos: preferDolbyAtmos
		) {
			// The policy orders the routes and the first one that produces a stream wins;
			// a hi-res result is a local decrypted file, a standard one is today's path.
			let source = stream.isHiResStereo ? "hi-res" : "online"
			print("Play \(track.title) from \(source) URL: \(stream.url)")
			print("[PLAYBACK] avSetItem(): resolved URL - title: \(track.title), quality: \(stream.isHiResStereo ? "hi-res stereo" : "\(stream.quality)"), source: \(source)")
			guard loadID == itemLoadID else {
				return nil
			}
			isPlayingHiResStereo = stream.isHiResStereo
			currentHiResBitDepth = stream.hiResBitDepth
			playbackInfo.resolvedStream = ResolvedStream(
				trackId: track.id,
				quality: stream.quality,
				isDolbyAtmos: stream.isDolbyAtmos,
				hiResBitDepth: stream.hiResBitDepth,
				hiResSampleRate: stream.hiResSampleRate
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

	/// A track that cannot play: counts the failure, then stops the queue once every
	/// track has failed or moves on to the next one.
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

	/// Installs `item` as the current one and observes its end and failure.
	///
	/// A failed or stalled item posts no end notification, so the status is observed
	/// directly. The identity check in the callback drops a late failure for an item
	/// the user has since replaced.
	private func installCurrentItem(_ item: AVPlayerItem) {
		NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: avPlayer.currentItem)
		NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: avPlayer.currentItem)
		NotificationCenter.default.addObserver(self, selector: #selector(self.playerDidFinishPlaying(sender:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item)
		NotificationCenter.default.addObserver(self, selector: #selector(self.playerItemFailedToPlayToEndTime(sender:)), name: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime, object: item)
		itemStatusObservation?.invalidate()
		itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
			guard item.status == .failed else { return }
			let description = item.error.map { String(describing: $0) }
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

	/// The item failed after playback started (the stream dropped, the decoder gave
	/// up). `AVPlayerItemDidPlayToEndTime` is not posted in that case, so without this
	/// the queue would sit on an item that will never play.
	@objc func playerItemFailedToPlayToEndTime(sender: Notification) {
		guard let item = sender.object as? AVPlayerItem, item === avPlayer.currentItem else { return }
		let description = (sender.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
			.map { String(describing: $0) }
		playerItemFailed(reason: "AVPlayerItemFailedToPlayToEndTime", errorDescription: description)
	}

	/// A loaded item that cannot play. Advances the way a refused stream does, so a
	/// track that fails at play time does not leave the UI believing it is playing.
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
		// Removing the current (possibly last) track can leave currentIndex at or
		// past the new end; clamp so the queue lookup below can't trap.
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
		// Describe the stream that plays, not what the track could offer: Tidal
		// reports Atmos tracks as `audioQuality: .low`, and an Atmos track plays
		// stereo when the preference is off. Resolution is async, so the stored
		// stream still belongs to the previous track until this one resolves;
		// say nothing then rather than borrow the previous track's label.
		guard let stream = playbackInfo.resolvedStream, stream.trackId == track.id else {
			return ""
		}
		if stream.isDolbyAtmos {
			return "Dolby Atmos"
		}
		if isPlayingHiResStereo {
			guard let bitDepth = stream.hiResBitDepth ?? currentHiResBitDepth else { return "Hi-Res" }
			guard let sampleRate = stream.hiResSampleRate, sampleRate > 0 else { return "\(bitDepth)-bit" }
			return "\(bitDepth)-bit \(Self.formattedSampleRate(sampleRate))"
		}
		guard let quality = track.audioQuality else {
			return ""
		}

		return qualityToString(quality: Self.clampedQuality(stream.quality, advertised: quality))
	}

	/// The direct `streamUrl` fallback answers a HI_RES_LOSSLESS request with the
	/// lossless 16 Bit / 44,1 kHz file, so a Max request that lands here is labelled
	/// as High. The desktop hi-res route reports its own bit depth and sample rate
	/// above and never reaches this clamp. See `AudioQuality.max`.
	private static func clampedQuality(_ resolved: AudioQuality, advertised: AudioQuality) -> AudioQuality {
		var quality = resolved
		if quality == .max {
			quality = .high
		}
		if quality == .high && (advertised == .medium || advertised == .low) {
			quality = .medium
		}
		if quality == .medium && advertised == .low {
			quality = .low
		}
		return quality
	}

	/// 44100 reads as "44.1kHz", 48000 as "48kHz" — the same shape the other tiers
	/// use, so the badge reads consistently whichever route played.
	private static func formattedSampleRate(_ sampleRate: Int) -> String {
		let kilohertz = Double(sampleRate) / 1000
		if kilohertz == kilohertz.rounded() {
			return "\(Int(kilohertz))kHz"
		}
		return String(format: "%.1fkHz", kilohertz)
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
			// The Max tier's advertised specification, never shown: `currentQualityString`
			// clamps `.max` to `.high` above, and the decrypted hi-res rendition is labelled
			// from its stream's own bit depth and sample rate.
			return "24-bit 192kHz"
		}
	}
}
