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
	@ObservedObject var loginInfo: LoginInfo
	@ObservedObject var playlistEditingValues: PlaylistEditingValues
	@ObservedObject var viewState: ViewState
	@ObservedObject var sortingState: SortingState

	let session: Session
	let player: Player

	var body: some View {
		TopDetailView(session: session, player: player)
			.environmentObject(viewState)
			.environmentObject(sortingState)
			.environmentObject(playlistEditingValues)
			.environmentObject(player.playbackInfo)
			.environmentObject(player.queueInfo)
			.environmentObject(session.helpers.downloadStatus)
			.background(EmptyView().sheet(isPresented: $loginInfo.showModal) {
				LoginView(loginInfo: loginInfo, viewState: viewState, session: session, player: player)
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
			.onAppear {
				// macOS 26 SwiftUI auto-focuses the first text field (search bar), which makes
				// the editing guard swallow menu shortcuts. Give focus back to the window content.
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
					if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
						window.makeFirstResponder(nil)
					}
				}
			}
	}
}
