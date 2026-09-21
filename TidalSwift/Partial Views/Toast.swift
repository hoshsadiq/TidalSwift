//
//  Toast.swift
//  TidalSwift
//
//  Created by TidalSwift Contributors on 21.09.26.
//  Copyright © 2026 TidalSwift Contributors. All rights reserved.
//

import SwiftUI

/// A transient, non-interactive message shown at the bottom centre of the window.
struct ToastView: View {
	let message: String

	var body: some View {
		Text(message)
			.font(.system(size: 13, weight: .medium))
			.foregroundStyle(.secondary)
			.multilineTextAlignment(.center)
			.lineLimit(2)
			.padding(.horizontal, 16)
			.padding(.vertical, 10)
			.background(.regularMaterial, in: Capsule())
			.shadow(color: .black.opacity(0.25), radius: 10, y: 3)
			// The capsule is always dark, so resolve its text in the dark scheme
			// regardless of the window's appearance.
			.environment(\.colorScheme, .dark)
	}
}

/// Presents `toastCenter`'s current message as a bottom-centre toast.
///
/// The toast fades in, holds for the duration set by `ToastCenter.show`, then
/// fades out. It never intercepts clicks.
private struct ToastModifier: ViewModifier {
	@ObservedObject var toastCenter: ToastCenter
	let bottomPadding: CGFloat

	func body(content: Content) -> some View {
		content.overlay(alignment: .bottom) {
			if let message = toastCenter.message {
				ToastView(message: message)
					.padding(.bottom, bottomPadding)
					.transition(.opacity)
					.allowsHitTesting(false)
			}
		}
		.animation(.easeInOut(duration: 0.2), value: toastCenter.message)
	}
}

extension View {
	/// Presents `toastCenter`'s current message as a bottom-centre toast.
	///
	/// `bottomPadding` lifts the toast clear of any bottom chrome (the player bar).
	func toast(_ toastCenter: ToastCenter, bottomPadding: CGFloat = 24) -> some View {
		modifier(ToastModifier(toastCenter: toastCenter, bottomPadding: bottomPadding))
	}
}
