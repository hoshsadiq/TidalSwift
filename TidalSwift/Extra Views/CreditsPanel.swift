//
//  CreditsPanel.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 17.09.26.
//  Copyright © 2026 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import TidalSwiftLib

/// Track credits panel of the expanded Now Playing drawer.
///
/// The panel is only mounted while the Credits pill is active, so the fetch in
/// `.task(id:)` runs when the panel opens — not when the drawer expands — and
/// re-runs when the playing track changes.
struct CreditsPanel: View {
	let session: Session
	let track: Track

	@State private var credits: [Credit] = []
	@State private var loadingState: LoadingState = .loading

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Credits")
				.font(.title3.weight(.semibold))
				.foregroundStyle(.primary)
				.padding(.bottom, 14)

			content
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.task(id: track.id) {
			await load()
		}
	}

	// MARK: - States

	@ViewBuilder
	private var content: some View {
		switch loadingState {
		case .loading:
			CreditsSkeleton()
		case .error:
			errorState
		case .successful:
			if sections.isEmpty {
				emptyState
			} else {
				creditsList
			}
		}
	}

	private var creditsList: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 22) {
				ForEach(sections) { section in
					VStack(alignment: .leading, spacing: 8) {
						Text(section.displayName)
							.font(.system(size: 13, weight: .semibold))
							.foregroundStyle(.primary)
						ForEach(section.names, id: \.self) { name in
							Text(name)
								.font(.system(size: 13))
								.foregroundStyle(Color.primary.opacity(0.72))
						}
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.bottom, 8)
		}
	}

	private var emptyState: some View {
		VStack(spacing: 8) {
			Image(systemName: "person.2.slash")
				.font(.system(size: 22))
			Text("No credits available")
				.font(.system(size: 13))
		}
		.foregroundStyle(Color.primary.opacity(0.55))
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	private var errorState: some View {
		VStack(spacing: 10) {
			Image(systemName: "exclamationmark.triangle")
				.font(.system(size: 22))
			Text("Couldn't load credits")
				.font(.system(size: 13))
			Button {
				Task { await load() }
			} label: {
				Text("Retry")
					.font(.system(size: 13, weight: .medium))
					.foregroundStyle(.primary)
					.padding(.horizontal, 16)
					.padding(.vertical, 6)
					.background(Capsule().fill(Color.primary.opacity(0.15)))
					.contentShape(Capsule())
			}
			.buttonStyle(.plain)
		}
		.foregroundStyle(Color.primary.opacity(0.7))
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: - Fetch

	private func load() async {
		loadingState = .loading
		let result = await session.trackCredits(trackId: track.id)
		// A cancelled task means the panel closed or the track changed; the
		// replacement task owns the state now.
		guard !Task.isCancelled else { return }
		credits = result ?? []
		loadingState = result == nil ? .error : .successful
	}

	// MARK: - Grouping

	/// One role section of the panel.
	private struct CreditSection: Identifiable {
		let role: String
		let names: [String]

		var id: String { role }
		var displayName: String { CreditsPanel.displayName(for: role) }
	}

	/// Roles that lead the panel, in order; every other role follows
	/// alphabetically.
	private static let rolePriority = ["Artist", "Vocals", "Composer", "Lyricist", "Producer"]

	/// The API returns some roles in singular form; those get a plural header,
	/// everything else keeps the API string verbatim.
	private static let pluralRoles: [String: String] = [
		"Artist": "Artists",
		"Composer": "Composers",
		"Producer": "Producers",
		"Lyricist": "Lyricists",
		"Engineer": "Engineers",
		"Mixer": "Mixers",
		"Vocalist": "Vocalists"
	]

	private static func displayName(for role: String) -> String {
		pluralRoles[role] ?? role
	}

	private static func sortKey(for role: String) -> (Int, String) {
		(rolePriority.firstIndex(of: role) ?? rolePriority.count, role.lowercased())
	}

	/// Credits grouped by role, deduplicated, in display order.
	private var sections: [CreditSection] {
		var order: [String] = []
		var grouped: [String: [String]] = [:]
		for credit in credits {
			var names = grouped[credit.type] ?? []
			if grouped[credit.type] == nil {
				order.append(credit.type)
			}
			for contributor in credit.contributors where !names.contains(contributor.name) {
				names.append(contributor.name)
			}
			grouped[credit.type] = names
		}
		return order
			.map { CreditSection(role: $0, names: grouped[$0] ?? []) }
			.filter { !$0.names.isEmpty }
			.sorted { Self.sortKey(for: $0.role) < Self.sortKey(for: $1.role) }
	}
}

/// Pulsing placeholder shown while the credits request is in flight.
private struct CreditsSkeleton: View {
	/// Row widths per section: three sections with two to three rows each.
	private let rows: [[CGFloat]] = [
		[132, 96, 118],
		[104, 148],
		[120, 88, 140]
	]

	@State private var pulsing = false

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			ForEach(Array(rows.enumerated()), id: \.offset) { _, widths in
				VStack(alignment: .leading, spacing: 8) {
					RoundedRectangle(cornerRadius: 4)
						.fill(Color.primary.opacity(0.22))
						.frame(width: 76, height: 11)
					ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
						RoundedRectangle(cornerRadius: 4)
							.fill(Color.primary.opacity(0.12))
							.frame(width: width, height: 10)
					}
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.opacity(pulsing ? 0.45 : 1)
		.animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
		.onAppear { pulsing = true }
	}
}
