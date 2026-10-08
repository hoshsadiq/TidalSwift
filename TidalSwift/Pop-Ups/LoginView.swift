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

	/// Asks what to do with downloaded files before logging out; `ContentView` presents it.
	var showLogoutConfirmation = false

	/// Lives here, not in the view, because the URL arrives through the scene's `.onOpenURL`.
	@ObservationIgnored var pendingDesktopLogin: PendingDesktopLogin?

	/// Ignored when no login is waiting, so unrelated `tidal://` links are harmless.
	func receive(callbackURL: URL) {
		// The callback carries the authorization code in its query, so log only the route.
		let route = "\(callbackURL.scheme ?? "?")://\(callbackURL.host() ?? "")\(callbackURL.path)"
		print("[LOGIN] callback arrived at \(route), waiting for a login: \(pendingDesktopLogin != nil)")
		pendingDesktopLogin?.resume(returning: callbackURL)
	}
}

/// One login attempt's wait for its browser callback. Each attempt owns its own
/// instance, so a cancelled attempt cannot resume the continuation of the one that
/// replaced it, and a result that arrives before `wait` is remembered.
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

private let desktopLoginTimeout: TimeInterval = 300

/// One value at a time, so the sheet never offers two methods at once.
private enum LoginPhase {
	case idle
	case systemBrowser
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
	@State private var secondsRemaining = Int(desktopLoginTimeout)
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

	@ViewBuilder
	private var pendingBrowser: some View {
		if let pendingLoginUrl {
			Button {
				openURL(pendingLoginUrl)
			} label: {
				Text("Open Browser")
			}

			if secondsRemaining > 0 {
				Text("Time remaining: \(secondsRemaining)")
					.task {
						while secondsRemaining > 0 {
							do {
								try await Task.sleep(for: .seconds(1))
							} catch {
								return
							}
							secondsRemaining -= 1
						}
					}
			} else {
				Text("Time expired")
			}
		}
	}

	/// Starts the login chain from the top; a second press restarts it.
	func startLogin() {
		authorizationTask?.cancel()
		loginNotice = nil
		loginError = nil
		pendingLoginUrl = nil
		phase = .idle
		authorizationTask = Task { await runLoginChain() }
	}

	/// Runs the chain in `LoginRoutePolicy`'s order: the browser while its `tidal://`
	/// callback can reach this app, then the device code, stopping at a cancel.
	private func runLoginChain() async {
		let decision = TidalLinkHandlingPolicy.decide(
			enabled: handleTidalLinks,
			handler: TidalLinkRegistration.currentHandler()
		)
		print("[LOGIN] starting chain: handleTidalLinks=\(handleTidalLinks), route=\(decision.route), registration=\(decision.registration)")
		let registrationAccepted = await TidalLinkRegistration.apply(decision.registration)
		// The claim's own result is authoritative: `setDefaultApplication` calls its
		// completion handler after any consent prompt, so an error-free return means the
		// scheme is ours. The handler read back right afterwards can still describe the
		// previous state, so it is a second opinion; using the browser when either signal
		// says so is safe, since a missing callback falls through to the device code.
		let handlerAfterRegistration = TidalLinkRegistration.currentHandler()
		print("[LOGIN] registration accepted: \(registrationAccepted), tidal:// handler now: \(TidalLinkRegistration.logDescription(of: handlerAfterRegistration))")
		let systemBrowserAvailable = decision.route == .browser
			&& (registrationAccepted || handlerAfterRegistration == .thisApp)

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
					loginNotice = handleTidalLinks
						? "Another app handles Tidal links, so the browser login cannot return here. Using a device code instead."
						: "Browser login is off in Settings, so the app is using a device code instead."
				}
				await runDeviceLogin()
				return
			}
		}
	}

	/// Returns nil when the login completed, and the reason it did not otherwise.
	private func runSystemBrowserLogin() async -> LoginRoutePolicy.End? {
		let verifier = DesktopLogin.generateCodeVerifier()
		let url = DesktopLogin.authorizeURL(codeChallenge: DesktopLogin.codeChallenge(for: verifier))
		let pending = PendingDesktopLogin()
		loginInfo.pendingDesktopLogin = pending
		pendingLoginUrl = url
		secondsRemaining = Int(desktopLoginTimeout)
		phase = .systemBrowser
		openURL(url)
		print("[LOGIN] opened authorize URL in the default browser: \(url.absoluteString)")
		do {
			let callback = try await waitForDesktopCallback(pending)
			print("[LOGIN] exchanging the callback code for a session")
			try await session.completeDesktopLogin(callbackURL: callback, codeVerifier: verifier)
			print("[LOGIN] browser login finished")
			successfulLogin()
			return nil
		} catch {
			let end = LoginRoutePolicy.end(for: error)
			switch end {
			case .cancelled:
				print("[LOGIN] browser login cancelled")
			case .timedOut:
				print("[LOGIN] browser login timed out waiting for the tidal:// callback")
				loginNotice = (error as? LocalizedError)?.errorDescription
			case .failed:
				print("[LOGIN] browser login failed: \(error)")
				loginError = (error as? LocalizedError)?.errorDescription ?? "Login failed"
			}
			return end
		}
	}

	private func runDeviceLogin() async {
		print("[LOGIN] starting device-code login")
		for await state in session.startAuthorization() {
			switch state {
			case .waiting:
				phase = .deviceCode
			case .pending(loginUrl: let loginUrl, expiration: _):
				phase = .deviceCode
				pendingLoginUrl = loginUrl
				secondsRemaining = Int(desktopLoginTimeout)
				openURL(loginUrl)
				print("[LOGIN] opened device-code URL in the default browser: \(loginUrl.absoluteString)")
			case .success:
				print("[LOGIN] device-code login finished")
				successfulLogin()
			case .failure(let error):
				print("[LOGIN] device-code login failed: \(error)")
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

	/// The timeout is the final fallback for when the `tidal://` callback cannot reach
	/// this app, so the sheet can offer the device code instead of spinning forever.
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
