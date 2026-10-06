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

	/// The system-browser login waits here for the `tidal://login/auth` callback. It
	/// lives on this app-wide object, not in the view, because the URL arrives
	/// through the scene's `.onOpenURL`, which cannot reach the view's state.
	@ObservationIgnored var pendingDesktopLogin: PendingDesktopLogin?

	/// Resumes the pending desktop-login wait. Ignored when no login is waiting,
	/// so unrelated `tidal://` links are harmless.
	func receive(callbackURL: URL) {
		pendingDesktopLogin?.resume(returning: callbackURL)
	}
}

/// One login attempt's wait for its browser callback. Each attempt
/// owns its own instance, so a cancelled attempt cannot resume the continuation of
/// the attempt that replaced it. The lock makes the resume safe to call from
/// the task-cancellation handler, and a result that arrives before `wait` is
/// remembered rather than dropped.
nonisolated final class PendingDesktopLogin: @unchecked Sendable {
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

/// How long the system-browser login waits for its callback before giving up.
private let desktopLoginTimeout: TimeInterval = 300

/// What the login sheet is doing. One value at a time, so the sheet never offers
/// two methods at once.
private enum LoginPhase {
	case idle
	/// Tidal's page is open in the browser, waiting for its `tidal://` callback.
	case systemBrowser
	/// Tidal's device-code flow is running.
	case deviceCode
}

struct LoginView: View {
	var loginInfo: LoginInfo
	var viewState: ViewState

	let session: Session

	@Environment(\.openURL) private var openURL

	@State private var phase: LoginPhase = .idle
	@State private var authorizationTask: Task<Void, Never>?
	@State private var pendingLoginUrl: URL?
	@State private var counter = 300
	@State private var loginNotice: String?
	@State private var loginError: String?

	/// Read live so the sheet's fallback order follows the Preferences toggle.
	@AppStorage(TidalLinkHandlingPreferences.enabledKey) private var handleTidalLinks = TidalLinkHandlingPreferences.defaultEnabled

	var body: some View {
		ScrollView {
			VStack {
				Image("Icon")
				Text("TidalSwift")
					.font(.largeTitle)

				loginForm
					.frame(minWidth: 300)
			}
			.padding()
		}
		.onDisappear {
			authorizationTask?.cancel()
		}
	}

	var loginForm: some View {
		VStack {
			switch phase {
			case .idle:
				Text("Sign in with your Tidal account. Tidal's page opens in your browser; come back here when you are done.")
			case .systemBrowser:
				pendingBrowser
			case .deviceCode:
				Text("Enter the code from the Tidal page to finish signing in.")
				pendingBrowser
			}

			if let loginNotice {
				Text(loginNotice)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}

			if let loginError {
				Text(loginError)
					.foregroundColor(.red)
					.multilineTextAlignment(.center)
			}

			Button(action: startLogin) {
				Text("Login")
			}
		}
		.padding()
	}

	/// The re-open button and countdown for the methods that send the user to a
	/// browser page of their own.
	@ViewBuilder
	private var pendingBrowser: some View {
		if let pendingLoginUrl {
			Button {
				openURL(pendingLoginUrl)
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
		}
	}

	/// Starts the login chain from the top. A second press restarts it.
	func startLogin() {
		authorizationTask?.cancel()
		loginNotice = nil
		loginError = nil
		pendingLoginUrl = nil
		phase = .idle
		authorizationTask = Task { await runLoginChain() }
	}

	/// Runs the login chain, one method at a time in `LoginRoutePolicy`'s order: the
	/// browser while its `tidal://` callback can reach this app — which is what the
	/// `handleTidalLinks` preference decides — then the device code. The chain starts
	/// at the device code when that callback cannot return, stops at the method that
	/// completes the login, and stops at a cancel.
	private func runLoginChain() async {
		let decision = TidalLinkHandlingPolicy.decide(
			enabled: handleTidalLinks,
			handler: TidalLinkRegistration.currentHandler()
		)
		let registrationAccepted = await TidalLinkRegistration.apply(decision.registration)
		// A claim the system declined leaves the scheme with another app, so the
		// callback could not return here; fall back at once instead of waiting it out.
		let claimDeclined = decision.route == .browser
			&& decision.registration == .claim
			&& !registrationAccepted
		let systemBrowserAvailable = decision.route == .browser && !claimDeclined

		var route: LoginRoutePolicy.Route? = LoginRoutePolicy.firstRoute(
			systemBrowserAvailable: systemBrowserAvailable
		)
		while let current = route {
			switch current {
			case .systemBrowser:
				guard let end = await runSystemBrowserLogin() else { return }
				route = LoginRoutePolicy.nextRoute(after: current, end: end)
			case .deviceCode:
				if !systemBrowserAvailable {
					loginNotice = claimDeclined
						? "Another app handles Tidal links, so the browser login cannot return here. Using a device code instead."
						: "Browser login is off in Settings, so the app is using a device code instead."
				}
				await runDeviceLogin()
				return
			}
		}
	}

	/// Runs the browser login: opens the authorize URL in the default browser and waits
	/// for the `tidal://login/auth` callback that `.onOpenURL` delivers.
	///
	/// Returns nil when the login completed, and the reason it did not otherwise; the
	/// sheet's line for that reason is set here too.
	private func runSystemBrowserLogin() async -> LoginRoutePolicy.End? {
		let verifier = DesktopLogin.generateCodeVerifier()
		let url = DesktopLogin.authorizeURL(codeChallenge: DesktopLogin.codeChallenge(for: verifier))
		let pending = PendingDesktopLogin()
		loginInfo.pendingDesktopLogin = pending
		pendingLoginUrl = url
		counter = 300
		phase = .systemBrowser
		openURL(url)
		do {
			let callback = try await waitForDesktopCallback(pending)
			try await session.completeDesktopLogin(callbackURL: callback, codeVerifier: verifier)
			successfulLogin()
			return nil
		} catch {
			let end = LoginRoutePolicy.end(for: error)
			switch end {
			case .cancelled:
				break
			case .timedOut:
				loginNotice = (error as? LocalizedError)?.errorDescription
			case .failed:
				loginError = (error as? LocalizedError)?.errorDescription ?? "Login failed"
			}
			return end
		}
	}

	/// Runs Tidal's device-code flow, the last method. Its page is Tidal's, so it
	/// keeps its own wording.
	private func runDeviceLogin() async {
		for await state in session.startAuthorization() {
			switch state {
			case .waiting:
				phase = .deviceCode
			case .pending(loginUrl: let loginUrl, expiration: _):
				phase = .deviceCode
				pendingLoginUrl = loginUrl
				counter = 300
				openURL(loginUrl)
			case .success:
				successfulLogin()
			case .failure(let error):
				loginError = (error as? LocalizedError)?.errorDescription ?? "Login failed"
				phase = .idle
			}
		}
	}

	private func successfulLogin() {
		loginNotice = nil
		loginError = nil
		loginInfo.showModal = false
		session.saveConfig()
		session.saveSession()
		viewState.push(view: TidalSwiftView(viewType: .collectionTracks))
	}

	/// Waits for `pending`'s callback, or fails with a timeout so the screen can
	/// offer the device-code fallback instead of spinning forever.
	///
	/// The desktop login's timeout is the final fallback for when the `tidal://`
	/// callback cannot reach this app.
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
