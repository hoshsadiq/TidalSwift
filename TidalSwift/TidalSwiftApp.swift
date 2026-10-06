//
//  AppDelegate.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import AppKit
import MediaPlayer
import Observation
import TidalSwiftLib
import UpdateNotification

@main
struct TidalSwiftApp: App {
	@State private var appModel = TidalSwiftAppModel()
	@Environment(\.scenePhase) private var scenePhase
	#if canImport(AppKit)
	@NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
	#endif

	var body: some Scene {
		WindowGroup("TidalSwift") {
			ContentView(
				loginInfo: appModel.loginInfo,
				playlistEditingValues: appModel.playlistEditingValues,
				viewState: appModel.viewState,
				sortingState: appModel.sortingState,
				session: appModel.session,
				player: appModel.player
			)
			.environment(appModel)
			.environment(appModel.toastCenter)
			.onAppear {
				#if canImport(AppKit)
				appDelegate.appModel = appModel
				#endif
				appModel.startupIfNeeded()
			}
			#if canImport(AppKit)
			.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
				appModel.prepareForTermination()
			}
			#endif
			.onChange(of: scenePhase) { _, newValue in
				if newValue != .active {
					appModel.saveState()
				}
			}
			// The desktop login's `tidal://login/auth` callback. SwiftUI's
			// `.onOpenURL` is the receiver because the app has no AppDelegate
			// open-URL handler, and the URL must reach the shared `LoginInfo`
			// that paused waiting for it. URLs with no pending login are ignored.
			.onOpenURL { url in
				appModel.loginInfo.receive(callbackURL: url)
			}
		}
		.commands {
			TidalSwiftCommands(appModel: appModel)
		}
		#if os(macOS)
		Settings {
			PreferencesView()
				.environment(appModel)
		}
		#endif
	}
}

#if canImport(AppKit)
/// Copy and Paste travel up the responder chain and land here only when nothing
/// focused handles them, so a text field keeps its own copy and paste.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
	weak var appModel: TidalSwiftAppModel?

	@objc func copy(_ sender: Any?) {
		guard let url = appModel?.viewState.currentShareUrl else { return }
		Pasteboard.copy(string: url.absoluteString)
	}

	@objc func paste(_ sender: Any?) {
		guard let link = Pasteboard.tidalLink() else { return }
		appModel?.viewState.open(link)
	}

	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		switch menuItem.action {
		case #selector(copy(_:)):
			appModel?.viewState.currentShareUrl != nil
		case #selector(paste(_:)):
			Pasteboard.tidalLink() != nil
		default:
			true
		}
	}
}
#endif

@Observable
final class TidalSwiftAppModel {
	let updateNotification = UpdateNotification(feedUrl: URL(string: "https://github.com/hoshsadiq/TidalSwift/releases/latest/download/TidalSwift.json")!)

	let session: Session
	let player: Player
	private let nowPlayingController: NowPlayingController
	var viewState: ViewState
	var sortingState: SortingState
	var playlistEditingValues = PlaylistEditingValues()
	let loginInfo = LoginInfo()
	/// Owns the app's single toast overlay; shared with `ContentView` through the
	/// environment so library errors routed via `displayErrorHandler` land here.
	let toastCenter = ToastCenter()

	private var didStart = false
	private var isTerminating = false

	#if canImport(AppKit)
	private var viewHistoryViewController: NSWindowController?
	private var playbackHistoryViewController: NSWindowController?
	private var miniplayerWindowController: MiniplayerWindowController?
	private var spaceKeyMonitor: Any?
	/// The app's main content window. Captured when the miniplayer opens so it can be
	/// hidden/shown for mutual exclusivity with the miniplayer.
	private var mainWindow: NSWindow?
	/// Observer for the main window becoming key (e.g., via Dock click), which should
	/// close the miniplayer to maintain mutual exclusivity.
	private var mainWindowKeyObserver: NSObjectProtocol?
	#endif

	// MARK: Cancellables

	// No public MPNowPlayingInfo constants exist for shuffle/repeat in MediaPlayer.
	// Best-effort keys; the system may ignore them. Shuffle/repeat state is
	// primarily driven via MPRemoteCommandCenter in NowPlayingController.
	private static let nowPlayingShuffleKey = "MPNowPlayingInfoPropertyShuffle"
	private static let nowPlayingRepeatKey = "MPNowPlayingInfoPropertyRepeat"

	/// UserDefaults key for the Preferences toggle that lets quality exceed the
	/// subscription cap. Shared with the view's `@AppStorage` so there is one spelling.
	static let ignoreSubscriptionLimitsKey = "ignoreSubscriptionLimits"

	@ObservationIgnored private var saveTask: Task<Void, Never>?
	/// Timestamp of the last Now Playing elapsed-time update. The player's time
	/// observer fires many times a second; this gates it back to the one-second
	/// cadence the previous Combine `.throttle` imposed.
	@ObservationIgnored private var lastNowPlayingFractionUpdate = Date.distantPast

	var trackIsFavorite = false
	var albumIsFavorite = false
	var showQueuePanel = false
	/// Whether the floating miniplayer window is currently open. Drives the
	/// drawer button's tint; kept in sync by the window's close callback.
	var isMiniplayerOpen = false
	private(set) var audioQuality: AudioQuality
	/// Highest quality the account's subscription allows, from `/users/{id}/subscription`.
	private(set) var highestSoundQuality: AudioQuality?

	var hasCurrentTrack: Bool {
		!player.queueInfo.queue.isEmpty
	}

	/// A toast holds two short lines; anything longer loses its tail on screen, so
	/// the full text goes to the console and the title is shown alone instead.
	private static let toastMessageLimit = 120

	init() {
		session = Session(config: nil)

		// The player's own Atmos preference. It was one shared toggle until now, so an
		// existing value under the offline key seeds the playback side on first launch
		// rather than resetting it to off.
		let preferDolbyAtmos: Bool
		if UserDefaults.standard.object(forKey: "preferDolbyAtmos") != nil {
			preferDolbyAtmos = UserDefaults.standard.bool(forKey: "preferDolbyAtmos")
		} else {
			preferDolbyAtmos = session.helpers.offline.preferDolbyAtmos
		}
		if let audioQualityString = UserDefaults.standard.string(forKey: "audioQuality"),
		   let audioQuality = AudioQuality(rawValue: audioQualityString) {
			player = Player(session: session, audioQuality: audioQuality, preferDolbyAtmos: preferDolbyAtmos)
		} else {
			player = Player(session: session, audioQuality: .high, preferDolbyAtmos: preferDolbyAtmos)
		}
		nowPlayingController = NowPlayingController(player: player, session: session)
		audioQuality = player.nextAudioQuality

		var cache = ViewCache()
		if let data = UserDefaults.standard.data(forKey: "ViewCache") {
			if let tempCache = try? JSONDecoder().decode(ViewCache.self, from: data) {
				cache = tempCache
			}
		}

		viewState = ViewState(session: session, cache: cache)
		sortingState = SortingState()

		// Installed here, not later, so an error raised as soon as the app calls into
		// the library (login, token refresh, the offline sync) already reaches the toast.
		installDisplayErrorHandler()
	}

	/// Routes library errors (`displayError`) to the app's toast centre. The session
	/// and the toast centre both exist by the end of `init`.
	private func installDisplayErrorHandler() {
		displayErrorHandler = { [toastCenter = self.toastCenter] title, content in
			let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
			let message = trimmedContent.isEmpty ? title : "\(title) — \(trimmedContent)"
			if message.count > Self.toastMessageLimit {
				print("\(title). \(content)")
				toastCenter.show(title)
			} else {
				toastCenter.show(message)
			}
		}
	}

	func startupIfNeeded() {
		guard !didStart else { return }
		didStart = true
		startup()
	}

	private func startup() {
		session.helpers.offline.uiRefreshFunc = { [weak self] in
			self?.viewState.refreshCurrentView()
		}

		let loggedIn = session.loadSession()
		print("Login Succesful: \(loggedIn)")
		loginInfo.showModal = !loggedIn

		if loggedIn {
			restorePlaybackState()
			restoreSortingState()
			restoreViewState()
			Task { await loadHighestSoundQuality() }
		}

		initCancellables()
		viewState.refreshCurrentView()
		refreshFavoriteState()

		#if canImport(AppKit)
		initSecondaryWindows()
		registerCloseLastWindowBehavior()
		registerSpaceKeyMonitor()

		updateCheck(showNoUpdatesAlert: false)
		#endif

		Task {
			await session.helpers.offline.syncAllOfflinePlaylistsAndFavoriteTracks()
		}
	}

	#if canImport(AppKit)
	func prepareForTermination() {
		guard !isTerminating else { return }
		isTerminating = true
		if let spaceKeyMonitor {
			NSEvent.removeMonitor(spaceKeyMonitor)
			self.spaceKeyMonitor = nil
		}
		if let mainWindowKeyObserver {
			NotificationCenter.default.removeObserver(mainWindowKeyObserver)
			self.mainWindowKeyObserver = nil
		}
		nowPlayingController.teardown()
		player.stopPrefetching()
		NowPlayingInfoBuilder.clear()
		cancelCancellables()
		closeModals()
		saveState()
	}

	func quit() {
		prepareForTermination()
		NSApp.terminate(nil)
	}

	private func registerCloseLastWindowBehavior() {
		_ = NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			let closingWindow = notification.object as? NSWindow
			// Safe because the observer asks for delivery on the main queue
			MainActor.assumeIsolated {
				self?.quitIfLastWindow(closing: closingWindow)
			}
		}
	}

	private func quitIfLastWindow(closing closingWindow: NSWindow?) {
		guard !isTerminating else { return }
		// The closing window still counts as visible while the notification is
		// being delivered, so ignore it and look for any other visible one
		let hasOtherVisibleWindow = NSApp.windows.contains { $0.isVisible && $0 !== closingWindow }
		if !hasOtherVisibleWindow {
			quit()
		}
	}

	// Menu-bar Space shortcuts are unreliable on macOS: focused scroll views consume
	// Space for page-scrolling before the menu bar matches key equivalents. This monitor
	// intercepts Space first; consuming the event also prevents double-toggle via the
	// Play/Pause menu item's .keyboardShortcut(.space).
	private func registerSpaceKeyMonitor() {
		guard spaceKeyMonitor == nil else { return }
		spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self,
				  event.keyCode == 49,
				  !event.isARepeat,
				  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .capsLock]).isEmpty,
				  let keyWindow = NSApp.keyWindow,
				  keyWindow.identifier?.rawValue != "com_apple_SwiftUI_Settings_window",
				  !(keyWindow.firstResponder is NSTextView) else {
				return event
			}
			self.togglePlay()
			return nil
		}
	}

	// MARK: Secondary Windows

	func initSecondaryWindows() {
		viewHistoryViewController = ResizableWindowControllerFactory.create(rootView:
			ViewHistoryView()
				.environment(viewState)
		)
		viewHistoryViewController?.window?.title = "View History"

		playbackHistoryViewController = ResizableWindowControllerFactory.create(
			rootView: PlaybackHistoryView(session: session, player: player)
				.environment(viewState)
				.environment(player.queueInfo)
		)
		playbackHistoryViewController?.window?.title = "Playback History"

		let miniplayerController = MiniplayerWindowController(session: session, player: player, viewState: viewState, appModel: self)
		miniplayerController.onClose = { [weak self] in
			self?.restoreMainWindowAfterMiniplayer()
		}
		miniplayerWindowController = miniplayerController
		registerMainWindowKeyObserver()
	}

	func closeAllSecondaryWindows() {
		viewHistoryViewController?.close()
		playbackHistoryViewController?.close()
		miniplayerWindowController?.close()
	}

	func showMiniplayer() {
		if mainWindow == nil,
		   let keyWindow = NSApp.keyWindow,
		   keyWindow !== miniplayerWindowController?.window {
			mainWindow = keyWindow
		}
		mainWindow?.orderOut(nil)
		miniplayerWindowController?.showWindow(nil)
		isMiniplayerOpen = true
	}

	func closeMiniplayer() {
		miniplayerWindowController?.close()
		restoreMainWindowAfterMiniplayer()
	}

	private func restoreMainWindowAfterMiniplayer() {
		isMiniplayerOpen = false
		mainWindow?.makeKeyAndOrderFront(nil)
		mainWindow = nil
	}

	private func registerMainWindowKeyObserver() {
		guard mainWindowKeyObserver == nil else { return }
		mainWindowKeyObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeKeyNotification,
			object: nil,
			queue: .main
		) { [weak self] notification in
			let window = notification.object as? NSWindow
			MainActor.assumeIsolated {
				guard let self,
					  self.isMiniplayerOpen,
					  let mainWindow = self.mainWindow,
					  let window,
					  window === mainWindow else { return }
				self.closeMiniplayer()
			}
		}
	}

	func toggleMiniplayer() {
		if isMiniplayerOpen {
			closeMiniplayer()
		} else {
			showMiniplayer()
		}
	}

	func showPlaybackHistoryWindow() {
		playbackHistoryViewController?.showWindow(nil)
	}

	func showViewHistoryWindow() {
		viewHistoryViewController?.showWindow(nil)
	}
	#endif

	// MARK: Persisting

	private func restorePlaybackState() {
		if let data = UserDefaults.standard.data(forKey: "PlaybackInfo") {
			if let codablePI = try? JSONDecoder().decode(CodablePlaybackInfo.self, from: data) {
				player.playbackInfo.volume = codablePI.volume
				player.playbackInfo.shuffle = codablePI.shuffle
				player.playbackInfo.repeatState = codablePI.repeatState
				player.playbackInfo.pauseAfter = codablePI.pauseAfter
				if let activePanel = codablePI.activePanel {
					player.playbackInfo.activePanel = activePanel
				}

				player.queueInfo.nonShuffledQueue = codablePI.nonShuffledQueue
				player.queueInfo.queue = codablePI.queue
				player.queueInfo.source = codablePI.source
				player.queueInfo.history = codablePI.history
				player.queueInfo.maxHistoryItems = codablePI.maxHistoryItems

				let restoredQueue = player.queueInfo.queue
				let notStreamReadyCount = restoredQueue.filter { !$0.track.streamReady }.count
				print("[PLAYBACK] restored queue - count: \(restoredQueue.count), currentIndex: \(codablePI.currentIndex), notStreamReady: \(notStreamReadyCount)")

				player.play(atIndex: codablePI.currentIndex)
				player.pause()
			}
		}
	}

	private func restoreSortingState() {
		if let data = UserDefaults.standard.data(forKey: "SortingState") {
			if let codableSS = try? JSONDecoder().decode(CodableSortingState.self, from: data) {
				sortingState.favoritePlaylistSorting = codableSS.favoritePlaylistSorting
				sortingState.favoritePlaylistReversed = codableSS.favoritePlaylistReversed
				sortingState.favoriteAlbumSorting = codableSS.favoriteAlbumSorting
				sortingState.favoriteAlbumReversed = codableSS.favoriteAlbumReversed
				sortingState.favoriteTrackSorting = codableSS.favoriteTrackSorting
				sortingState.favoriteTrackReversed = codableSS.favoriteTrackReversed
				sortingState.favoriteVideoSorting = codableSS.favoriteVideoSorting
				sortingState.favoriteVideoReversed = codableSS.favoriteVideoReversed
				sortingState.favoriteArtistSorting = codableSS.favoriteArtistSorting
				sortingState.favoriteArtistReversed = codableSS.favoriteArtistReversed
				sortingState.offlinePlaylistSorting = codableSS.offlinePlaylistSorting
				sortingState.offlinePlaylistReversed = codableSS.offlinePlaylistReversed
				sortingState.offlineAlbumSorting = codableSS.offlineAlbumSorting
				sortingState.offlineAlbumReversed = codableSS.offlineAlbumReversed
				sortingState.offlineTrackSorting = codableSS.offlineTrackSorting
				sortingState.offlineTrackReversed = codableSS.offlineTrackReversed
			}
		}
	}

	private func restoreViewState() {
		if let data = UserDefaults.standard.data(forKey: "ViewStateStack") {
			viewState.stack = decodeViewArray(from: data)
		}

		if let data = UserDefaults.standard.data(forKey: "ViewStateForwardStack") {
			viewState.forwardStack = decodeViewArray(from: data)
		}

		// Land on the Music view when there is no persisted non-base view to restore.
		if !viewState.stack.contains(where: { !$0.isBase() }) {
			viewState.stack = [TidalSwiftView(viewType: .music)]
			viewState.forwardStack.removeAll()
		}

		if let searchTerm = UserDefaults.standard.string(forKey: "SearchTerm") {
			viewState.searchTerm = searchTerm
			viewState.lastSearchTerm = searchTerm
		}

		if let data = UserDefaults.standard.data(forKey: "ViewStateHistory") {
			viewState.history = decodeViewArray(from: data)
		}
		let tempMaxHistoryItems = UserDefaults.standard.integer(forKey: "ViewStateHistoryMaxItems")
		if tempMaxHistoryItems != 0 {
			viewState.maxHistoryItems = tempMaxHistoryItems
		} else {
			viewState.maxHistoryItems = 100
		}
	}

	/// Decodes a persisted view array one entry at a time. A single entry whose
	/// `viewType` no longer exists — a page that was removed, for example — fails
	/// the whole-array decode and would otherwise discard the entire stack,
	/// forward stack or history.
	private func decodeViewArray(from data: Data) -> [TidalSwiftView] {
		guard let rawEntries = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
			return []
		}
		return rawEntries.compactMap { entry in
			guard let entryData = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
			return try? JSONDecoder().decode(TidalSwiftView.self, from: entryData)
		}
	}

	func savePlaybackState() {
		let codablePI = CodablePlaybackInfo(
			fraction: player.playbackInfo.fraction,
			volume: player.playbackInfo.volume,
			shuffle: player.playbackInfo.shuffle,
			repeatState: player.playbackInfo.repeatState,
			pauseAfter: player.playbackInfo.pauseAfter,
			activePanel: player.playbackInfo.activePanel,
			nonShuffledQueue: player.queueInfo.nonShuffledQueue,
			queue: player.queueInfo.queue,
			currentIndex: player.queueInfo.currentIndex,
			source: player.queueInfo.source,
			history: player.queueInfo.history,
			maxHistoryItems: player.queueInfo.maxHistoryItems
		)
		let playbackInfoData = try? JSONEncoder().encode(codablePI)
		UserDefaults.standard.set(playbackInfoData, forKey: "PlaybackInfo")
		UserDefaults.standard.set(player.nextAudioQuality.rawValue, forKey: "audioQuality")
		UserDefaults.standard.set(player.preferDolbyAtmos, forKey: "preferDolbyAtmos")
	}

	func saveViewState() {
		UserDefaults.standard.set(viewState.searchTerm, forKey: "SearchTerm")
		let viewStackData = try? JSONEncoder().encode(viewState.stack)
		UserDefaults.standard.set(viewStackData, forKey: "ViewStateStack")
		let viewForwardStackData = try? JSONEncoder().encode(viewState.forwardStack)
		UserDefaults.standard.set(viewForwardStackData, forKey: "ViewStateForwardStack")
		let viewHistoryData = try? JSONEncoder().encode(viewState.history)
		UserDefaults.standard.set(viewHistoryData, forKey: "ViewStateHistory")
		UserDefaults.standard.set(viewState.maxHistoryItems, forKey: "ViewStateHistoryMaxItems")
	}

	func saveFavoritesSortingState() {
		let codableSS = CodableSortingState(
			favoritePlaylistSorting: sortingState.favoritePlaylistSorting,
			favoritePlaylistReversed: sortingState.favoritePlaylistReversed,
			favoriteAlbumSorting: sortingState.favoriteAlbumSorting,
			favoriteAlbumReversed: sortingState.favoriteAlbumReversed,
			favoriteTrackSorting: sortingState.favoriteTrackSorting,
			favoriteTrackReversed: sortingState.favoriteTrackReversed,
			favoriteVideoSorting: sortingState.favoriteVideoSorting,
			favoriteVideoReversed: sortingState.favoriteVideoReversed,
			favoriteArtistSorting: sortingState.favoriteArtistSorting,
			favoriteArtistReversed: sortingState.favoriteArtistReversed,
			offlinePlaylistSorting: sortingState.offlinePlaylistSorting,
			offlinePlaylistReversed: sortingState.offlinePlaylistReversed,
			offlineAlbumSorting: sortingState.offlineAlbumSorting,
			offlineAlbumReversed: sortingState.offlinePlaylistReversed,
			offlineTrackSorting: sortingState.offlineTrackSorting,
			offlineTrackReversed: sortingState.offlineTrackReversed
		)
		let codableSSData = try? JSONEncoder().encode(codableSS)
		UserDefaults.standard.set(codableSSData, forKey: "SortingState")
	}

	func saveViewCache() {
		let viewCacheData = try? JSONEncoder().encode(viewState.cache)
		UserDefaults.standard.set(viewCacheData, forKey: "ViewCache")
	}

	func saveState() {
		session.saveConfig()
		session.saveSession()
		savePlaybackState()
		saveViewState()
		saveViewCache()
		saveFavoritesSortingState()
	}

	func closeModals() {
		loginInfo.showModal = false
		playlistEditingValues.showAddTracksModal = false
		playlistEditingValues.showRemoveTracksModal = false
		playlistEditingValues.showDeleteModal = false
		playlistEditingValues.showEditModal = false
	}

	private func updateNowPlayingForTrackChange() {
		let queue = player.queueInfo.queue
		let currentIndex = player.queueInfo.currentIndex
		guard !queue.isEmpty, queue.indices.contains(currentIndex) else {
			NowPlayingInfoBuilder.clear()
			return
		}
		let track = queue[currentIndex].track
		MPNowPlayingInfoCenter.default().nowPlayingInfo = NowPlayingInfoBuilder.build(player: player, session: session)
		NowPlayingInfoBuilder.updatePlaybackState(player.playbackInfo.playing ? .playing : .paused)
		Task { [weak self] in
			guard let self else { return }
			guard let artwork = await NowPlayingInfoBuilder.fetchArtwork(session: self.session, track: track) else { return }
			let nowIndex = self.player.queueInfo.currentIndex
			guard self.player.queueInfo.queue.indices.contains(nowIndex),
				  self.player.queueInfo.queue[nowIndex].track.id == track.id else { return }
			MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
		}
	}

	func initCancellables() {
		setupNowPlayingCancellables()
		startSaveLoop()
	}

	/// Observes a Now Playing input and re-arms after every change. Each helper
	/// re-registers itself because `withObservationTracking` fires `onChange` only
	/// once, before the new value is written; the handler therefore runs on the
	/// next main-actor turn, with the new value in place.
	private func setupNowPlayingCancellables() {
		observeNowPlayingPlaying()
		observeNowPlayingFraction()
		observeNowPlayingShuffle()
		observeNowPlayingRepeatState()
		observeNowPlayingQueue()
		observeNowPlayingCurrentIndex()
	}

	private func observeNowPlayingPlaying() {
		withObservationTracking {
			_ = player.playbackInfo.playing
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.updateNowPlayingPlaybackState()
				self?.observeNowPlayingPlaying()
			}
		}
	}

	private func updateNowPlayingPlaybackState() {
		NowPlayingInfoBuilder.updatePlaybackState(player.playbackInfo.playing ? .playing : .paused)
		let oldArtwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork]
		var info = NowPlayingInfoBuilder.build(player: player, session: session)
		if !info.isEmpty, let artwork = oldArtwork {
			info[MPMediaItemPropertyArtwork] = artwork
		}
		MPNowPlayingInfoCenter.default().nowPlayingInfo = info.isEmpty ? nil : info
	}

	private func observeNowPlayingFraction() {
		withObservationTracking {
			_ = player.playbackInfo.fraction
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.updateNowPlayingElapsedTime()
				self?.observeNowPlayingFraction()
			}
		}
	}

	private func observeNowPlayingShuffle() {
		withObservationTracking {
			_ = player.playbackInfo.shuffle
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.updateNowPlayingShuffle()
				self?.observeNowPlayingShuffle()
			}
		}
	}

	private func updateNowPlayingShuffle() {
		MPNowPlayingInfoCenter.default().nowPlayingInfo?[Self.nowPlayingShuffleKey] = player.playbackInfo.shuffle
	}

	private func observeNowPlayingRepeatState() {
		withObservationTracking {
			_ = player.playbackInfo.repeatState
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.updateNowPlayingRepeatState()
				self?.observeNowPlayingRepeatState()
			}
		}
	}

	private func updateNowPlayingRepeatState() {
		MPNowPlayingInfoCenter.default().nowPlayingInfo?[Self.nowPlayingRepeatKey] = player.playbackInfo.repeatState.rawValue
	}

	private func observeNowPlayingQueue() {
		withObservationTracking {
			_ = player.queueInfo.queue
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.updateNowPlayingForTrackChange()
				self?.refreshFavoriteState()
				self?.observeNowPlayingQueue()
			}
		}
	}

	private func observeNowPlayingCurrentIndex() {
		withObservationTracking {
			_ = player.queueInfo.currentIndex
		} onChange: { [weak self] in
			Task { @MainActor in
				self?.updateNowPlayingForTrackChange()
				self?.refreshFavoriteState()
				self?.observeNowPlayingCurrentIndex()
			}
		}
	}

	/// Writes the elapsed playback time to the Now Playing centre at most once a
	/// second, matching the previous Combine `.throttle` on `fraction`.
	private func updateNowPlayingElapsedTime() {
		let now = Date()
		guard now.timeIntervalSince(lastNowPlayingFractionUpdate) >= 1 else { return }
		lastNowPlayingFractionUpdate = now

		let currentIndex = player.queueInfo.currentIndex
		guard !player.queueInfo.queue.isEmpty,
			  player.queueInfo.queue.indices.contains(currentIndex) else { return }
		let elapsed = Double(player.queueInfo.queue[currentIndex].track.duration) * Double(player.playbackInfo.fraction)
		MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
	}

	/// Saves unsaved changes every 10 seconds, and only then: nothing is written
	/// up front, matching the previous 10-second timer publisher's first fire.
	private func startSaveLoop() {
		saveTask = Task { [weak self] in
			while !Task.isCancelled {
				do {
					try await Task.sleep(for: .seconds(10))
				} catch {
					return
				}
				self?.saveUnsavedChanges()
			}
		}
	}

	private func saveUnsavedChanges() {
		if player.playbackInfo.hasUnsavedChanges || player.queueInfo.hasUnsavedChanges {
			player.playbackInfo.hasUnsavedChanges = false
			player.queueInfo.hasUnsavedChanges = false
			savePlaybackState()
		}
		if viewState.hasUnsavedChanges {
			viewState.hasUnsavedChanges = false
			saveViewState()
		}
		if sortingState.hasUnsavedChanges {
			sortingState.hasUnsavedChanges = false
			saveFavoritesSortingState()
		}
	}

	func cancelCancellables() {
		saveTask?.cancel()
	}

	// MARK: Menu Actions

	#if canImport(AppKit)
	func checkForUpdates() {
		updateCheck(showNoUpdatesAlert: true)
	}
	#endif

	func showChangelog() {
		#if canImport(AppKit)
		updateNotification.showChangelogWindow()
		#else
		print("Not implemented")
		#endif
	}

	#if canImport(AppKit)
	func updateCheck(showNoUpdatesAlert: Bool) {
		Task {
			do {
				if try await updateNotification.checkForUpdates() {
					updateNotification.showNewVersionView()
				} else if showNoUpdatesAlert {
					let alert = NSAlert()
					alert.messageText = "No updates available"
					alert.informativeText = "You are already on the latest version"
					alert.alertStyle = .informational
					alert.addButton(withTitle: "OK")
					alert.runModal()
				}
			} catch {
				print("Checking for updates failed: \(error)")
			}
		}
	}
	#endif

	func find() {
		NotificationCenter.default.post(name: .focusSearchField, object: nil)
	}

	func downloadTrack() {
		guard hasCurrentTrack else { return }
		let track = player.queueInfo.queue[player.queueInfo.currentIndex].track
		Task { [self] in
			_ = await session.helpers.download.download(track: track, audioQuality: player.nextAudioQuality)
		}
	}

	func goToAlbum() {
		guard hasCurrentTrack else { return }
		let track = player.queueInfo.queue[player.queueInfo.currentIndex].track
		viewState.push(album: track.album)
	}

	func goToArtist() {
		guard hasCurrentTrack else { return }
		let track = player.queueInfo.queue[player.queueInfo.currentIndex].track
		guard !track.artists.isEmpty else { return }
		viewState.push(artist: track.artists[0])
	}

	func addCurrentTrackToFavorites() {
		guard hasCurrentTrack else { return }
		let trackId = player.queueInfo.queue[player.queueInfo.currentIndex].track.id
		Task {
			if await session.favorites?.addTrack(trackId: trackId) == true {
				session.helpers.offline.asyncSyncFavoriteTracks()
				refreshFavoriteState()
				viewState.refreshCurrentView()
			}
		}
	}

	func removeCurrentTrackFromFavorites() {
		guard hasCurrentTrack else { return }
		let trackId = player.queueInfo.queue[player.queueInfo.currentIndex].track.id
		Task {
			if await session.favorites?.removeTrack(trackId: trackId) == true {
				session.helpers.offline.asyncSyncFavoriteTracks()
				refreshFavoriteState()
				viewState.refreshCurrentView()
			}
		}
	}

	func addCurrentTrackToPlaylist() {
		guard hasCurrentTrack else { return }
		let track = player.queueInfo.queue[player.queueInfo.currentIndex].track
		playlistEditingValues.tracks = [track]
		playlistEditingValues.showAddTracksModal = true
	}

	func addCurrentAlbumToFavorites() {
		guard hasCurrentTrack else { return }
		let albumId = player.queueInfo.queue[player.queueInfo.currentIndex].track.album.id
		Task {
			if await session.favorites?.addAlbum(albumId: albumId) == true {
				refreshFavoriteState()
				viewState.refreshCurrentView()
			}
		}
	}

	func removeCurrentAlbumFromFavorites() {
		guard hasCurrentTrack else { return }
		let albumId = player.queueInfo.queue[player.queueInfo.currentIndex].track.album.id
		Task {
			if await session.favorites?.removeAlbum(albumId: albumId) == true {
				refreshFavoriteState()
				viewState.refreshCurrentView()
			}
		}
	}

	func addQueueToPlaylist() {
		let tracks = player.queueInfo.queue.unwrapped()
		playlistEditingValues.tracks = tracks
		playlistEditingValues.showAddTracksModal = true
	}

	func togglePlay() {
		player.togglePlay()
	}

	func stop() {
		player.stop()
	}

	func next() {
		player.next()
	}

	func previous() {
		player.previous()
	}

	func increaseVolume() {
		player.increaseVolume()
	}

	func decreaseVolume() {
		player.decreaseVolume()
	}

	func toggleMute() {
		player.toggleMute()
	}

	func toggleShuffle() {
		player.playbackInfo.shuffle.toggle()
	}

	func setRepeatState(_ repeatState: RepeatState) {
		player.playbackInfo.repeatState = repeatState
	}

	func togglePauseAfterCurrentTrack() {
		player.playbackInfo.pauseAfter.toggle()
	}

	func setAudioQuality(_ audioQuality: AudioQuality) {
		player.setAudioQuality(to: audioQuality)
		player.playbackInfo.hasUnsavedChanges = true
		self.audioQuality = audioQuality
	}

	func setPreferDolbyAtmos(_ preferDolbyAtmos: Bool) {
		player.setPreferDolbyAtmos(to: preferDolbyAtmos)
		player.playbackInfo.hasUnsavedChanges = true
	}

	func isAudioQualitySelected(_ audioQuality: AudioQuality) -> Bool {
		self.audioQuality == audioQuality
	}

	/// Whether the subscription allows this tier. The rule lives in
	/// `AudioQualityPolicy` so it can be tested without a view or a session. An
	/// unknown subscription (fetch failed or not logged in yet) allows everything,
	/// so options are never hidden on a guess. The "Ignore subscription limits"
	/// preference bypasses the cap so a tier above the subscription becomes
	/// selectable.
	func isAudioQualityAvailable(_ quality: AudioQuality) -> Bool {
		AudioQualityPolicy.isAvailable(
			quality,
			subscriptionHighest: highestSoundQuality,
			ignoringLimits: UserDefaults.standard.bool(forKey: Self.ignoreSubscriptionLimitsKey)
		)
	}

	/// Fetches the subscription's cap, which drives the disabled quality rows.
	/// Deliberately does not rewrite `audioQuality`: a chosen tier must never be
	/// changed behind the user's back. A tier Tidal refuses degrades gracefully in
	/// `bestAudioUrl`, which walks the ladder downward.
	func loadHighestSoundQuality() async {
		guard let highest = await session.subscriptionInfo()?.highestSoundQuality else { return }
		highestSoundQuality = highest
	}

	func clearQueue() {
		player.clearQueue(leavingCurrent: true)
	}

	func accountInfo() {
		#if canImport(AppKit)
		guard let userId = session.userId else { return }
		Task {
			guard let user = await session.user(userId: userId) else { return }
			let controller = ResizableWindowControllerFactory.create(rootView:
				AccountInfoView(session: session)
			)
			controller.window?.title = user.username
			controller.showWindow(nil)
		}
		#else
		print("Coming soon")
		#endif
	}

	func refreshAccessToken() {
		Task {
			do {
				try await session.refreshAccessToken()
			} catch {
				print("Refresh Access Token failed. Error: \(error)")
			}
		}
	}

	/// Ends the session. `removeDownloads` decides what happens to the offline
	/// library: by default it is left completely alone, and only an explicit
	/// choice deletes the files. The offline decision is made before
	/// `session.logout()`, so it does not depend on the session still being valid.
	func logout(removeDownloads: Bool = false) {
		if removeDownloads {
			session.helpers.offline.removeAll()
		}
		closeModals()
		#if canImport(AppKit)
		closeAllSecondaryWindows()
		#endif
		player.clearQueue()
		session.logout()
		viewState.clearEverything()
		loginInfo.showModal = true
		trackIsFavorite = false
		albumIsFavorite = false
	}

	func removeAllOfflineContent() {
		Task {
			session.helpers.offline.removeAll()
			viewState.clearEverything()
		}
	}

	func refreshFavoriteState() {
		guard hasCurrentTrack else {
			trackIsFavorite = false
			albumIsFavorite = false
			return
		}

		let track = player.queueInfo.queue[player.queueInfo.currentIndex].track
		Task {
			let trackFavorite = await track.isInFavorites(session: session) ?? false
			let albumFavorite = await track.album.isInFavorites(session: session) ?? false
			self.trackIsFavorite = trackFavorite
			self.albumIsFavorite = albumFavorite
		}
	}
}

struct TidalSwiftCommands: Commands {
	var appModel: TidalSwiftAppModel

	var body: some Commands {
		#if canImport(AppKit)
		CommandGroup(after: .appInfo) {
			Button("Check for Updates") {
				appModel.checkForUpdates()
			}
			Button("Changelog") {
				appModel.showChangelog()
			}
		}

		CommandGroup(replacing: .appTermination) {
			Button("Quit TidalSwift") {
				appModel.quit()
			}
			.keyboardShortcut("q")
		}
		#endif

		CommandMenu("Track") {
			Button("Go to Album") {
				appModel.goToAlbum()
			}
			.disabled(!appModel.hasCurrentTrack)

			Button("Go to Artist") {
				appModel.goToArtist()
			}
			.disabled(!appModel.hasCurrentTrack)

				if appModel.trackIsFavorite {
					Button("Remove from Favorites") {
						appModel.removeCurrentTrackFromFavorites()
					}
					.disabled(!appModel.hasCurrentTrack)
				} else {
					Button("Add to Favorites") {
						appModel.addCurrentTrackToFavorites()
					}
					.disabled(!appModel.hasCurrentTrack)
				}

			Button("Add to Playlist") {
				appModel.addCurrentTrackToPlaylist()
			}
			.disabled(!appModel.hasCurrentTrack)

				if appModel.albumIsFavorite {
					Button("Remove Album from Favorites") {
						appModel.removeCurrentAlbumFromFavorites()
					}
					.disabled(!appModel.hasCurrentTrack)
				} else {
					Button("Add Album to Favorites") {
						appModel.addCurrentAlbumToFavorites()
					}
					.disabled(!appModel.hasCurrentTrack)
				}

			Button("Add Queue to Playlist") {
				appModel.addQueueToPlaylist()
			}
			.disabled(appModel.player.queueInfo.queue.isEmpty)
		}

		CommandMenu("Control") {
			Button(appModel.player.playbackInfo.playing ? "Pause" : "Play") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.togglePlay()
			}
			.keyboardShortcut(.space, modifiers: [])
			Button("Stop") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.stop()
			}
			.keyboardShortcut(".", modifiers: .command)
			Button("Next") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.next()
			}
			.keyboardShortcut(.rightArrow, modifiers: .command)
			Button("Previous") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.previous()
			}
			.keyboardShortcut(.leftArrow, modifiers: .command)
			Button("Seek Forward") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				guard !appModel.player.queueInfo.queue.isEmpty else { return }
				let currentIndex = appModel.player.queueInfo.currentIndex
				guard appModel.player.queueInfo.queue.indices.contains(currentIndex) else { return }
				let track = appModel.player.queueInfo.queue[currentIndex].track
				guard track.duration > 0 else { return }
				let newFraction = min(max((Double(appModel.player.playbackInfo.fraction) * Double(track.duration) + 15.0) / Double(track.duration), 0.0), 1.0)
				appModel.player.seek(to: newFraction)
			}
			.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
			Button("Seek Backward") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				guard !appModel.player.queueInfo.queue.isEmpty else { return }
				let currentIndex = appModel.player.queueInfo.currentIndex
				guard appModel.player.queueInfo.queue.indices.contains(currentIndex) else { return }
				let track = appModel.player.queueInfo.queue[currentIndex].track
				guard track.duration > 0 else { return }
				let newFraction = min(max((Double(appModel.player.playbackInfo.fraction) * Double(track.duration) - 15.0) / Double(track.duration), 0.0), 1.0)
				appModel.player.seek(to: newFraction)
			}
			.keyboardShortcut(.leftArrow, modifiers: [.command, .option])

			Divider()

			Button("Increase Volume") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.increaseVolume()
			}
			.keyboardShortcut(.upArrow, modifiers: .command)
			Button("Decrease Volume") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.decreaseVolume()
			}
			.keyboardShortcut(.downArrow, modifiers: .command)
			Toggle("Mute", isOn: Binding(
				get: { appModel.player.playbackInfo.volume == 0 },
				set: { _ in
					guard !KeyboardGuard.isTextEntryActive else { return }
					appModel.toggleMute()
				}
			))
			.keyboardShortcut("m", modifiers: [.command, .control])

			Divider()

			Toggle("Shuffle", isOn: Binding(
				get: { appModel.player.playbackInfo.shuffle },
				set: { _ in
					guard !KeyboardGuard.isTextEntryActive else { return }
					appModel.toggleShuffle()
				}
			))
			.keyboardShortcut("s", modifiers: .command)

			Button("Repeat") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.player.playbackInfo.repeatState = appModel.player.playbackInfo.repeatState.next()
			}
			.keyboardShortcut("r", modifiers: .command)

			Toggle("Pause After Current Track", isOn: Binding(
				get: { appModel.player.playbackInfo.pauseAfter },
				set: { _ in appModel.togglePauseAfterCurrentTrack() }
			))

			Menu("Audio Quality") {
				audioQualityButton(title: "Low", quality: .low)
				audioQualityButton(title: "High", quality: .medium)
				audioQualityButton(title: "HiFi", quality: .high)
				audioQualityButton(title: "Max", quality: .max)
			}

			Button("Clear Queue") {
				appModel.clearQueue()
			}
			.disabled(appModel.player.queueInfo.queue.isEmpty)

			Divider()

			Button("Favorite Current Track") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				guard !appModel.player.queueInfo.queue.isEmpty else { return }
				let queue = appModel.player.queueInfo.queue
				let currentIndex = appModel.player.queueInfo.currentIndex
				guard queue.indices.contains(currentIndex) else { return }
				let trackId = queue[currentIndex].track.id
				Task {
					guard let favorites = appModel.session.favorites else { return }
					guard let isFavorite = await favorites.doFavoritesContainTrack(trackId: trackId) else { return }
					let success: Bool
					if isFavorite {
						success = await favorites.removeTrack(trackId: trackId)
					} else {
						success = await favorites.addTrack(trackId: trackId)
					}
					if success {
						appModel.session.helpers.offline.asyncSyncFavoriteTracks()
						appModel.refreshFavoriteState()
						// Keep the row in the current list; only update its heart.
						NotificationCenter.default.post(name: .favoriteTrackChanged, object: nil, userInfo: ["trackId": trackId, "isFavorite": !isFavorite])
					}
				}
			}
		}

		CommandMenu("Account") {
			Button("Account Info") {
				appModel.accountInfo()
			}
			Button("Refresh Access Token") {
				appModel.refreshAccessToken()
			}
			Button("Logout") {
				appModel.loginInfo.showLogoutConfirmation = true
			}
			Button("Remove All Offline Content") {
				appModel.removeAllOfflineContent()
			}
		}

		#if canImport(AppKit)
		CommandGroup(after: .windowArrangement) {
			Divider()
			Button("Lyrics") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				withAnimation(.easeInOut(duration: 0.3)) {
					appModel.player.playbackInfo.isNowPlayingExpanded = true
					appModel.player.playbackInfo.activePanel = .lyrics
				}
			}
			.keyboardShortcut("l", modifiers: .command)
			Button("Queue") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				withAnimation {
					appModel.showQueuePanel.toggle()
				}
			}
			.keyboardShortcut("p", modifiers: .command)
			Button("Playback History") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.showPlaybackHistoryWindow()
			}
			.keyboardShortcut("k", modifiers: .command)
			Button("View History") {
				guard !KeyboardGuard.isTextEntryActive else { return }
				appModel.showViewHistoryWindow()
			}
			.keyboardShortcut("u", modifiers: .command)
		}
		#endif

		CommandGroup(after: .textEditing) {
			Button("Find") {
				appModel.find()
			}
			.keyboardShortcut("f")
		}

		CommandGroup(after: .newItem) {
			Button("Download Track") {
				appModel.downloadTrack()
			}
			.disabled(!appModel.hasCurrentTrack)
		}
	}

	@ViewBuilder
	private func audioQualityButton(title: String, quality: AudioQuality) -> some View {
		Button {
			appModel.setAudioQuality(quality)
		} label: {
			if appModel.isAudioQualitySelected(quality) {
				Label(title, systemImage: "checkmark")
			} else {
				Text(title)
			}
		}
		.disabled(!appModel.isAudioQualityAvailable(quality))
	}
}
