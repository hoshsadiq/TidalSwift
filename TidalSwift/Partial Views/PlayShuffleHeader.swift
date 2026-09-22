//
//  PlayShuffleHeader.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 22.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI

/// The Play + Shuffle button row shared by the mix detail page and the
/// Collection ▸ Tracks screen.
///
/// Deliberately model-free: it takes plain callbacks so the same row can drive
/// a mix, a playlist or a track list without knowing which. The caller owns the
/// queue logic, which keeps this view reusable and testable in isolation.
struct PlayShuffleHeader: View {
	let onPlay: () -> Void
	let onShuffle: () -> Void
	/// Off by default so a screen that only wants Play can hide Shuffle.
	var showsShuffle: Bool = true

	var body: some View {
		HStack(spacing: 10) {
			Button(action: onPlay) {
				Label("Play", systemImage: "play.fill")
					.font(.system(size: 13, weight: .semibold))
					.foregroundColor(.black)
					.padding(.horizontal, 18)
					.frame(height: 36)
					.background(Color.white, in: Capsule())
			}
			.buttonStyle(.plain)

			if showsShuffle {
				Button(action: onShuffle) {
					Label("Shuffle", systemImage: "shuffle")
						.font(.system(size: 13, weight: .semibold))
						.foregroundColor(.white)
						.padding(.horizontal, 18)
						.frame(height: 36)
						.background(Color.white.opacity(0.15), in: Capsule())
				}
				.buttonStyle(.plain)
			}
		}
	}
}
