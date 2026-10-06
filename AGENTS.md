# Repository Guidelines

## About This Project

TidalSwift is a macOS Tidal Music Streaming Client written in Swift. It supports streaming, offline playback, downloads, lyrics, playlist management, and a Music tab that renders TIDAL's v2 home feed — all via the unofficial Tidal API.

## Project Structure & Module Organization

`TidalSwift` contains the macOS app target (views, UI helpers, assets, and app lifecycle code).
`TidalSwiftLib` contains the reusable API/client library (session endpoints, codable models, downloads, metadata, and networking).
`TidalSwift.xcodeproj` defines shared schemes for both targets.
`README.assets` stores images used in project documentation, not runtime app assets.
`docs` holds developer notes: API research, investigations, and plans for larger changes. Check it for background before working on a related area, and add findings there that are worth keeping but don't belong in code comments.

Keep app-facing code in `TidalSwift/...` and platform-agnostic API/domain logic in `TidalSwiftLib/...`.

## Architecture

### Key Subsystems

**Networking (`TidalSwiftLib/Network.swift`):** Async/await HTTP client supporting GET/POST/DELETE. All Tidal API calls go through `Session` (`TidalSwiftLib/Session/Session.swift`), which holds auth state and constructs requests. API credentials live in `TidalSwiftLib/Config.swift` — treat these as sensitive.

**State Management (`TidalSwift/Helpers/`):**
- `ViewState.swift` — navigation stack, view history, and per-view cached content
- `PlaybackInfo.swift` — observable playback metadata (current track, position)
- `QueueInfo.swift` — observable queue state
- `SortingState.swift` — observable sort preferences

All state objects are `@Observable` classes, injected with `.environment(_:)` and read via `@Environment(Type.self)` (or passed directly, with `@Bindable` where a view needs bindings). Persisted properties set an `@ObservationIgnored` `hasUnsavedChanges` flag in `didSet`. `TidalSwiftAppModel` in `TidalSwiftApp.swift` owns all instances and saves flagged state to UserDefaults via JSON encoding from a 10-second task loop and on app quit. The project doesn't use Combine.

**Player (`TidalSwift/Player.swift`):** Thin `AVPlayer` wrapper that manages the playback queue, shuffle, repeat, and stream URL resolution. Each track is resolved through `HiResStreamingPolicy.routes`, which leads with Tidal's desktop `playbackinfo` rendition and keeps the older direct stream as the fallback.

**Playback quality & streaming route (`TidalSwiftLib/HiResStreaming.swift`, `TidalSwiftLib/Session/ContentUrls.swift`):** `HiResStreamingPolicy.routes` picks the route per play: the desktop `playbackinfo` rendition at Max and High (a FLAC decrypted into a local file), the assembled AAC DASH file at Low and Medium, then the direct `streamUrl` ladder as fallback. Dolby Atmos is a preference that forces the direct route when the track has an Atmos rendition. `AudioQualityPolicy` decides which tiers the subscription may pick; `HiResStreamingPreferences` holds the prefetch depth and cache budget. Prepared tracks are cached under `~/Library/Caches/TidalSwift/stream/` and pruned to the budget, so a prepared track plays from disk.

**Login (`TidalSwiftLib/DesktopLogin.swift`, `TidalSwiftLib/Session/Login.swift`):** The desktop client's PKCE flow is the preferred path. `startDesktopAuthorization` in `Pop-Ups/LoginView.swift` opens the browser and waits for the `tidal://login/auth` callback (the scheme is registered in `TidalSwift/Info.plist`; the scene's `.onOpenURL` hands the URL to `LoginInfo.receive`). Its token carries the `cuk` claim read by `Session.hasHiResStereoAccess`, which is what makes Tidal serve the hi-res stereo rendition. The device-code flow (`Session.startAuthorization`) is the fallback.

**Content decryption (`TidalSwiftLib/AudioDecryption.swift`):** The desktop rendition arrives encrypted with Tidal's legacy `OLD_AES`. `AudioDecryption` unwraps the `keyId` with a fixed master key and decrypts the file with AES-128-CTR into the playback cache. Tidal serves the 24-bit stereo rendition no other way, so this is the only route to it; the key is public because the third-party Tidal clients published it, not a secret in this codebase.

**Offline & Downloads (`TidalSwiftLib/`):** The `Offline` and `Download` modules handle caching tracks locally and syncing favorites for offline use. `Metadata` tags downloaded tracks without dependencies: `FLACTagWriter` writes Vorbis comment and picture blocks, `MP4TagWriter` uses an AVFoundation passthrough export. Sync keeps one audio file per track, matched to the current offline quality, and removes files of other variants; per-track added dates are recorded so the Collection screens can show them, and `completeOfflineAlbums` repairs stored albums that arrived without artists. Logging out leaves the library untouched; only `TidalSwiftAppModel.logout(removeDownloads:)` with the remove option deletes the files.

**Models (`TidalSwiftLib/Codables/`):** `Codable` structs for every Tidal entity — `Album`, `Artist`, `Track`, `Video`, `Playlist`, login responses, etc.

### Swift Package Manager Dependencies

- `UpdateNotification` — in-app update checking

## Build, Test, and Development Commands

Use Xcode's MCP if possible.

- `open TidalSwift.xcodeproj`
  Open the project in Xcode.
- `xcodebuild -project TidalSwift.xcodeproj -scheme TidalSwift -configuration Debug build`
  Build the macOS app from CLI.
- `xcodebuild -project TidalSwift.xcodeproj -scheme TidalSwiftLib -configuration Debug build`
  Build the framework target.

There is no test suite for the app target. `TidalSwiftLib` has one: run `mise run test-lib`, which is what the CI library job runs. `mise run scan` runs Periphery across both targets to flag unused code. If `mise run build` fails due to local cache issues, build directly in Xcode and capture the exact error in the PR.

Run the app with `mise run app`, which builds it, then launches the copy in this checkout. It also unregisters every other copy of `TidalSwift.app` that has ever been launched — earlier worktree builds, the Periphery cache, an installed copy — because each one claims the `tidal://` scheme, and LaunchServices picks among them when the login callback arrives. A stale path can swallow it, which looks like a login that opens the wrong app or never returns. `TIDY_ONLY=1 mise run app` does the tidying without launching, and `LAUNCH_DETACHED=1` launches with `open` instead of in the foreground. It runs the binary directly so the app's `[LOGIN]` and `[PLAYBACK]` console lines arrive in the terminal; a launched app's output goes nowhere.
Tests must stay away from the developer's own data: never let a test read the stored session (`Session(config: nil)` does, through `Config.load()`), and never let one write to the real offline folder — construct a `TemporaryOfflineLibrary` and pass its root to `Session`.

## Coding Style & Naming Conventions

Indent with tabs, one per level, never spaces. Xcode and many tools default to four spaces, so check new code. `.editorconfig` encodes this for editors that support it.
Types use `UpperCamelCase`; functions/properties use `lowerCamelCase`; file names match the primary type/feature (`ArtistView.swift`, `SearchResults.swift`).
Prefer `async/await` over callback-style APIs for new async work (the codebase was recently migrated from callbacks).
Never mess with indentation or whitespace on unrelated lines, but make sure that new or edited blocks have correct indentation.
Blank lines are truly empty, with no trailing whitespace — the pinned `trailing-whitespace` hook strips any that appears, and CI runs it with `--all-files`. Editors often leave indentation on a blank line, so check the diff of new or edited code for whitespace-only lines (`git diff | grep -nE '^\+[[:space:]]+$'`).
Default Actor Isolation is set to `MainActor` and Approachable Concurrency is enabled for both `TidalSwift` and `TidalSwiftLib`.

## Commit & Pull Request Guidelines

Match the existing commit style: short, imperative, and specific (`Fix login`, `Update Xcode project`, `Bump build number`).
Keep commits scoped to one logical change.
PRs should include:
- concise summary of user-visible/technical changes
- linked issue (if available)
- manual test notes
- screenshots or recordings for UI changes

## Security & Configuration Tips

Do not add personal tokens, account data, or local secrets to commits.
Treat auth/config constants in `TidalSwiftLib/Config.swift` as sensitive integration settings; discuss API/auth changes in the PR description.
