//
//  ContentView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.08.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import AppKit
import TidalSwiftLib

struct ContentView: View {
	var loginInfo: LoginInfo
	var playlistEditingValues: PlaylistEditingValues
	var viewState: ViewState
	var sortingState: SortingState

	@Environment(ToastCenter.self) private var toastCenter

	let session: Session
	let player: Player

	/// Keeps the toast clear of the player bar (64pt content + top padding + divider).
	private static let toastBottomInset: CGFloat = 96

	var body: some View {
		@Bindable var loginInfo = loginInfo
		@Bindable var playlistEditingValues = playlistEditingValues
		TopDetailView(session: session, player: player)
			.environment(viewState)
			.environment(sortingState)
			.environment(playlistEditingValues)
			.environment(player.playbackInfo)
			.environment(player.queueInfo)
			.environment(session.helpers.downloadStatus)
			.environment(toastCenter)
			.toast(toastCenter, bottomPadding: Self.toastBottomInset)
			.background(EmptyView().sheet(isPresented: $loginInfo.showModal) {
				LoginView(loginInfo: loginInfo, viewState: viewState, session: session)
			})
			.background(EmptyView().sheet(isPresented: $playlistEditingValues.showAddTracksModal) {
				AddToPlaylistView(session: session, playlistEditingValues: playlistEditingValues, viewState: viewState)
			})
			.background(EmptyView().sheet(isPresented: $playlistEditingValues.showRemoveTracksModal) {
				RemoveFromPlaylistView(session: session, playlistEditingValues: playlistEditingValues, viewState: viewState)
			})
			.background(EmptyView().sheet(isPresented: $playlistEditingValues.showDeleteModal) {
				DeletePlaylistView(session: session, playlistEditingValues: playlistEditingValues, viewState: viewState)
			})
			.background(EmptyView().sheet(isPresented: $playlistEditingValues.showEditModal) {
				EditPlaylistView(session: session, playlistEditingValues: playlistEditingValues, viewState: viewState)
			})
			#if canImport(AppKit)
			.touchBar {
				TouchBarView(player: player, playbackInfo: player.playbackInfo)
			}
			#endif
			.task {
				do {
					try await session.refreshAccessTokenIfNeeded()
					try await session.populateVariablesForAccessToken()
				} catch SessionError.network(let underlying) {
					// The stored credentials may still be valid — keep the session
					print("Couldn't reach Tidal on startup: \(underlying)")
				} catch {
					loginInfo.showModal = true
				}
			}
	}
}
