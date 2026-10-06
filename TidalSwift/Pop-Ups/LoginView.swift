//
//  LoginView.swift
//  TidalSwift
//
//  Created by Melvin Gundlach on 16.10.19.
//  Copyright © 2019 Melvin Gundlach. All rights reserved.
//

import SwiftUI
import AppKit
import TidalSwiftLib

@Observable final class LoginInfo {
	var showModal = false

	/// Asks what to do with the downloaded files before logging out. The app model
	/// sets it from the Account menu; `ContentView` presents the dialog.
	var showLogoutConfirmation = false

	/// The desktop login waits here for the `tidal://login/auth` callback. It
	/// lives on this app-wide object, not in the view, because the URL arrives
	/// through the scene's `.onOpenURL`, which cannot reach the view's state.
	@ObservationIgnored var pendingDesktopLogin: PendingDesktopLogin?

	/// Resumes the pending desktop-login wait. Ignored when no login is waiting,
	/// so unrelated `tidal://` links are harmless.
	func receive(callbackURL: URL) {
		pendingDesktopLogin?.resume(returning: callbackURL)
	}
}

/// One desktop-login attempt's wait for its browser callback. Each attempt owns
/// its own instance, so a cancelled attempt cannot resume the continuation of
/// the attempt that replaced it. The lock makes the resume safe to call from
/// the task-cancellation handler, and a result that arrives before `wait` is
/// remembered rather than dropped.
final class PendingDesktopLogin: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<URL, Error>?
	private var result: Result<URL, Error>?

	func wait() async throws -> URL {
		try await withCheckedThrowingContinuation { continuation in
			lock.lock()
			defer { lock.unlock() }
			if let result {
				continuation.resume(with: result)
			} else {
				self.continuation = continuation
			}
		}
	}

	func resume(returning url: URL) {
		finish(with: .success(url))
	}

	func resume(throwing error: Error) {
		finish(with: .failure(error))
	}

	private func finish(with result: Result<URL, Error>) {
		lock.lock()
		if let continuation {
			self.continuation = nil
			lock.unlock()
			continuation.resume(with: result)
		} else if self.result == nil {
			self.result = result
			lock.unlock()
		} else {
			lock.unlock()
		}
	}
}

/// How long the desktop login waits for the browser callback before giving up.
private let desktopLoginTimeout: TimeInterval = 300

struct LoginView: View {
	var loginInfo: LoginInfo
	var viewState: ViewState

	let session: Session

	@Environment(\.openURL) private var openURL

	@State var authorizationTask: Task<Void, Never>?
	@State var authState: Session.AuthorizationState = .waiting
	@State var counter = 300

	@State var refreshToken: String = ""
	@State var clientID: String = ""
	@State var loginErrorMessage: String?
	@State var desktopError: String?

	var body: some View {
		ScrollView {
			VStack {
				Image("Icon")
				Text("TidalSwift")
					.font(.largeTitle)

				TabView {
					deviceLogin
						.tabItem { Text("Device Login") }

					authLogin
						.tabItem { Text("Authorization") }
				}
				.frame(minWidth: 300)
			}
			.textFieldStyle(RoundedBorderTextFieldStyle())
			.padding()
		}
		.onDisappear {
			authorizationTask?.cancel()
		}
	}

	var deviceLogin: some View {
		VStack {
			switch authState {
			case .waiting:
				Text("Login mechinism, which works via the webbrowser")
			case .pending(loginUrl: let loginUrl, expiration: _):
				if let desktopError {
					Text(desktopError)
						.foregroundColor(.red)
				}

				Button {
					openURL(loginUrl)
				} label: {
					Text("Open Browser")
				}

				if counter > 0 {
					Text("Time remaining: \(counter)")
						.task {
							while counter > 0 {
								do {
									try await Task.sleep(for: .seconds(1))
								} catch {
									return
								}
								counter -= 1
							}
						}
				} else {
					Text("Time expired")
				}
			case .success:
				EmptyView()
			case .failure(_):
				VStack {
					Text(desktopError ?? "Something went wrong")
						.foregroundColor(.red)
					if desktopError != nil {
						Button {
							desktopError = nil
							startAuthorization()
						} label: {
							Text("Use Device Login")
						}
					}
				}
			}

			Button(action: startDesktopAuthorization) {
				Text("Login")
			}
		}
		.padding()
	}

	var authLogin: some View {
		VStack {
			SecureField("Refresh Token", text: $refreshToken)

			TextField("Client ID", text: $clientID)

			if let loginErrorMessage {
				Text(loginErrorMessage)
					.foregroundColor(.red)
			}

			Button(action: setAuthorization) {
				Text("Login")
			}
		}
		.padding()
	}

	func startAuthorization() {
		authorizationTask?.cancel()
		authorizationTask = Task {
			for await state in session.startAuthorization() {
				authState = state
				switch state {
				case .waiting:
					break
				case .pending(loginUrl: let loginUrl, expiration: _):
					counter = 300
					openURL(loginUrl)
				case .success:
					successfulLogin()
				case .failure(_):
					break
				}
			}
		}
	}

	func setAuthorization() {
		Task {
			do {
				try await session.login(refreshToken: refreshToken, clientID: clientID)
				successfulLogin()
			} catch SessionError.invalidCredentials {
				loginErrorMessage = "Wrong Login Credentials"
			} catch SessionError.network {
				loginErrorMessage = "Couldn't reach Tidal. Check your internet connection."
			} catch {
				loginErrorMessage = "Login failed"
			}
		}
	}

	func successfulLogin() {
		loginErrorMessage = nil
		desktopError = nil
		loginInfo.showModal = false
		session.saveConfig()
		session.saveSession()
		viewState.push(view: TidalSwiftView(viewType: .collectionTracks))
	}

	/// Starts the official desktop client's PKCE login, the preferred path.
	/// Opens the browser, then waits for the `tidal://login/auth` callback that
	/// `LoginInfo.receive` delivers. A timeout or any failure falls through to
	/// the `deviceLogin` failure state, which offers the device-code flow.
	func startDesktopAuthorization() {
		guard callbackSchemeReachesThisApp else {
			desktopError = "Another app handles tidal:// links, so the browser login could not return here. Using device login instead."
			startAuthorization()
			return
		}
		authorizationTask?.cancel()
		desktopError = nil
		authState = .waiting
		let pending = PendingDesktopLogin()
		loginInfo.pendingDesktopLogin = pending
		authorizationTask = Task {
			do {
				let verifier = DesktopLogin.generateCodeVerifier()
				let url = DesktopLogin.authorizeURL(codeChallenge: DesktopLogin.codeChallenge(for: verifier))
				counter = 300
				authState = .pending(loginUrl: url, expiration: Date().addingTimeInterval(desktopLoginTimeout))
				openURL(url)
				let callback = try await waitForDesktopCallback(pending)
				try await session.completeDesktopLogin(callbackURL: callback, codeVerifier: verifier)
				successfulLogin()
				authState = .success
			} catch is CancellationError {
				// The sheet closed or another attempt started; nothing to show.
			} catch {
				desktopError = (error as? LocalizedError)?.errorDescription ?? "Login failed"
				authState = .failure(error)
			}
		}
	}

	/// Whether macOS will hand `tidal://` callbacks to this app. The official TIDAL
	/// desktop app registers the same scheme, and LaunchServices silently picks one
	/// winner, so the browser login can be routed to TIDAL and the callback never
	/// arrives. Asking before opening the browser turns the full 300 s wait into the
	/// device login the user is offered after the timeout anyway. A nil answer means
	/// no app claims the scheme and so the check cannot tell: the desktop login still
	/// starts, and its timeout stays the fallback.
	private var callbackSchemeReachesThisApp: Bool {
		guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "tidal://")!) else {
			return true
		}
		return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
	}

	/// Waits for `pending`'s callback, or fails with a timeout so the screen can
	/// offer the device-code fallback instead of spinning forever.
	///
	/// The desktop login's timeout is the final fallback for when
	/// `callbackSchemeReachesThisApp` cannot tell who owns the scheme.
	private func waitForDesktopCallback(_ pending: PendingDesktopLogin) async throws -> URL {
		do {
			return try await withThrowingTaskGroup(of: URL.self) { group in
				group.addTask {
					try await withTaskCancellationHandler {
						try await pending.wait()
					} onCancel: {
						pending.resume(throwing: CancellationError())
					}
				}
				group.addTask {
					try await Task.sleep(for: .seconds(desktopLoginTimeout))
					throw DesktopLogin.LoginError.timeout
				}
				defer { group.cancelAll() }
				guard let url = try await group.next() else { throw DesktopLogin.LoginError.timeout }
				return url
			}
		} catch {
			pending.resume(throwing: error)
			throw error
		}
	}
}
