# TODO

## Upstream contribution (parked 2026-10-07)

The fork absorbed upstream's work and then fixed what that exposed. Sending any of it back is a
separate job: a series of small pull requests, each built on `upstream/main` alone so no pull
request depends on another. It waits on a reply from `melgu` about whether they want it at all.

The tooling pull request is written and builds, at `.worktrees/tooling-pr` (XcodeGen, mise tasks
and prek hooks, so the project file stops being tracked). Upstream's tree does not compile on
Xcode 26.6 for two unrelated reasons in their own code; the pull request describes those rather
than working around them.

Order, smallest first:

1. **Tooling**: XcodeGen, mise tasks, prek hooks.
2. **Tests**: the library suite, with the temp-library and credential guards.
3. **Fixes that need no design argument**: artwork that no longer blanks while scrolling, the
   queue's total duration, VoiceOver labels for repeat, shuffle and mute, the login readback,
   logout durability.
4. **Behaviour work**: favourites paging, offline variant sync, download tagging.
5. **Contested, and theirs to decide**: the hi-res route. It reaches 24-bit stereo by decrypting
   TIDAL's content encryption with a publicly documented key, and it carries TIDAL's own desktop
   client id. Their developer documentation states that the SDK's Player module is the only
   allowed way for third parties to play TIDAL content, so this one is not ours to slip in.

## Also parked

- **Fork wind-down**: flipping the bundle id to `de.melgu.TidalSwift` resets saved navigation,
  preferences and playback state, so it wants a deliberate decision rather than a surprise.
- **Session tokens in UserDefaults**: what a fix would take is written down in
  `docs/security-followups.md`.
