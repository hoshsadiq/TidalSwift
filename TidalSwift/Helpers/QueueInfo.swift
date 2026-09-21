//
//  QueueInfo.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 01.08.20.
//  Copyright © 2020 Melvin Gundlach. All rights reserved.
//

import Foundation
import Combine
import TidalSwiftLib

struct QueueSource: Codable, Equatable {
	enum CollectionType: String, Codable {
		case playlist
		case album
		case artist
		case favorite
		case mix
	}

	var type: CollectionType
	var title: String
	var id: String?
}

final class QueueInfo: ObservableObject {
	var nonShuffledQueue = [WrappedTrack]()
	@Published var queue = [WrappedTrack]()
	@Published var currentIndex: Int = 0

	@Published var source: QueueSource?

	@Published var history: [WrappedTrack] = []
	var maxHistoryItems: Int = 100

	var currentItem: WrappedTrack? {
		queue.element(at: currentIndex)
	}

	func assignQueueIndices() {
		for i in 0..<queue.count {
			queue[i] = WrappedTrack(id: i, track: queue[i].track)
			if i < nonShuffledQueue.count {
				nonShuffledQueue[i] = WrappedTrack(id: i, track: nonShuffledQueue[i].track)
			}
		}
	}

	func addToHistory(track: Track) {
		// Ensure Track only exists once in History
		history.removeAll(where: { $0.track == track })

		history.append(WrappedTrack(id: 0, track: track))

		// Enforce Maximum
		if history.count >= maxHistoryItems {
			history.removeFirst(history.count - maxHistoryItems)
		}

		assignHistoryIndices()
	}

	func assignHistoryIndices() {
		for i in 0..<history.count {
			history[i] = WrappedTrack(id: i, track: history[i].track)
		}
	}

	func clearHistory() {
		history.removeAll()
	}
}
