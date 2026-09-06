import Foundation
import MediaPlayer
import TidalSwiftLib

@MainActor final class NowPlayingController {
	private let player: Player
	private let session: Session
	private let commandCenter: MPRemoteCommandCenter

	init(player: Player, session: Session) {
		self.player = player
		self.session = session
		self.commandCenter = MPRemoteCommandCenter.shared()

		registerCommands()
	}

	deinit {}

	func teardown() {
		commandCenter.playCommand.removeTarget(nil)
		commandCenter.pauseCommand.removeTarget(nil)
		commandCenter.togglePlayPauseCommand.removeTarget(nil)
		commandCenter.nextTrackCommand.removeTarget(nil)
		commandCenter.previousTrackCommand.removeTarget(nil)
		commandCenter.skipForwardCommand.removeTarget(nil)
		commandCenter.skipBackwardCommand.removeTarget(nil)
		commandCenter.changePlaybackPositionCommand.removeTarget(nil)
		commandCenter.changeShuffleModeCommand.removeTarget(nil)
		commandCenter.changeRepeatModeCommand.removeTarget(nil)
		commandCenter.likeCommand.removeTarget(nil)
		commandCenter.dislikeCommand.removeTarget(nil)
	}

	private func registerCommands() {
		let player = player
		let session = session

		commandCenter.playCommand.isEnabled = true
		commandCenter.playCommand.addTarget { _ in
			Task { @MainActor in
				player.play()
			}
			return .success
		}

		commandCenter.pauseCommand.isEnabled = true
		commandCenter.pauseCommand.addTarget { _ in
			Task { @MainActor in
				player.pause()
			}
			return .success
		}

		commandCenter.togglePlayPauseCommand.isEnabled = true
		commandCenter.togglePlayPauseCommand.addTarget { _ in
			Task { @MainActor in
				player.togglePlay()
			}
			return .success
		}

		commandCenter.nextTrackCommand.isEnabled = true
		commandCenter.nextTrackCommand.addTarget { _ in
			Task { @MainActor in
				guard Self.currentTrack(for: player) != nil else { return }
				player.next()
			}
			return .success
		}

		commandCenter.previousTrackCommand.isEnabled = true
		commandCenter.previousTrackCommand.addTarget { _ in
			Task { @MainActor in
				guard Self.currentTrack(for: player) != nil else { return }
				player.previous()
			}
			return .success
		}

		let skipForwardCommand = commandCenter.skipForwardCommand as MPSkipIntervalCommand
		skipForwardCommand.isEnabled = true
		skipForwardCommand.preferredIntervals = [NSNumber(value: 15.0)]
		skipForwardCommand.addTarget { event in
			guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
			Task { @MainActor in
				guard let percentage = Self.seekPercentage(player: player, interval: event.interval) else { return }
				player.seek(to: percentage)
			}
			return .success
		}

		let skipBackwardCommand = commandCenter.skipBackwardCommand as MPSkipIntervalCommand
		skipBackwardCommand.isEnabled = true
		skipBackwardCommand.preferredIntervals = [NSNumber(value: 15.0)]
		skipBackwardCommand.addTarget { event in
			guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
			Task { @MainActor in
				guard let percentage = Self.seekPercentage(player: player, interval: -event.interval) else { return }
				player.seek(to: percentage)
			}
			return .success
		}

		commandCenter.changePlaybackPositionCommand.isEnabled = true
		commandCenter.changePlaybackPositionCommand.addTarget { event in
			guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
			Task { @MainActor in
				guard let percentage = Self.seekPercentage(player: player, positionTime: event.positionTime) else { return }
				player.seek(to: percentage)
			}
			return .success
		}

		let changeShuffleModeCommand = commandCenter.changeShuffleModeCommand as MPChangeShuffleModeCommand
		changeShuffleModeCommand.isEnabled = true
		changeShuffleModeCommand.currentShuffleType = player.playbackInfo.shuffle ? .items : .off
		changeShuffleModeCommand.addTarget { event in
			guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
			switch event.shuffleType {
			case .items:
				Task { @MainActor in
					player.shuffle(enabled: true)
				}
				return .success
			case .off:
				Task { @MainActor in
					player.shuffle(enabled: false)
				}
				return .success
			default:
				return .commandFailed
			}
		}

		let changeRepeatModeCommand = commandCenter.changeRepeatModeCommand as MPChangeRepeatModeCommand
		changeRepeatModeCommand.isEnabled = true
		changeRepeatModeCommand.currentRepeatType = Self.repeatType(for: player.playbackInfo.repeatState)
		changeRepeatModeCommand.addTarget { event in
			guard let event = event as? MPChangeRepeatModeCommandEvent,
				let repeatState = Self.repeatState(for: event.repeatType) else { return .commandFailed }
			Task { @MainActor in
				player.playbackInfo.repeatState = repeatState
			}
			return .success
		}

		commandCenter.likeCommand.isEnabled = true
		commandCenter.likeCommand.localizedTitle = "Favorite"
		commandCenter.likeCommand.addTarget { _ in
			Task { @MainActor in
				guard let track = Self.currentTrack(for: player) else { return }
				_ = await session.favorites?.addTrack(trackId: track.id)
			}
			return .success
		}

		commandCenter.dislikeCommand.isEnabled = true
		commandCenter.dislikeCommand.localizedTitle = "Unfavorite"
		commandCenter.dislikeCommand.addTarget { _ in
			Task { @MainActor in
				guard let track = Self.currentTrack(for: player) else { return }
				_ = await session.favorites?.removeTrack(trackId: track.id)
			}
			return .success
		}
	}

	// MPRemoteCommand handlers can arrive off the main actor; helpers are @MainActor and called from Task { @MainActor in } blocks.
	private static func currentTrack(for player: Player) -> Track? {
		guard !player.queueInfo.queue.isEmpty, player.queueInfo.currentIndex < player.queueInfo.queue.count else { return nil }
		return player.queueInfo.queue[player.queueInfo.currentIndex].track
	}

	private static func seekPercentage(player: Player, interval: TimeInterval) -> Double? {
		guard let track = currentTrack(for: player), track.duration > 0 else { return nil }
		let currentSeconds = Double(player.playbackInfo.fraction) * Double(track.duration)
		let newFraction = (currentSeconds + interval) / Double(track.duration)
		return clamped(newFraction)
	}

	private static func seekPercentage(player: Player, positionTime: TimeInterval) -> Double? {
		guard let track = currentTrack(for: player), track.duration > 0 else { return nil }
		return clamped(positionTime / Double(track.duration))
	}

	private static func clamped(_ value: Double) -> Double {
		min(max(value, 0.0), 1.0)
	}

	nonisolated private static func repeatType(for repeatState: RepeatState) -> MPRepeatType {
		switch repeatState {
		case .off:
			return .off
		case .all:
			return .all
		case .single:
			return .one
		}
	}

	nonisolated private static func repeatState(for repeatType: MPRepeatType) -> RepeatState? {
		switch repeatType {
		case .off:
			return .off
		case .all:
			return .all
		case .one:
			return .single
		default:
			return nil
		}
	}
}
