# Security follow-ups

Things a security review flagged that this branch does not fix, with the reason and what
it would take. The rest of that review's findings are fixed: credentials no longer reach
stdout, the token exchange's response body is not printed, and the segment error that
carried a signed URL into a user-visible message now names only the host.

## Session tokens live in UserDefaults

`Session.saveConfig()` writes the access token, refresh token and API token into
`UserDefaults.standard`, under `Config Information`. Anything running as the same user can
read them, and they are not encrypted at rest beyond whatever FileVault provides. Upstream
does the same, so this is inherited rather than introduced.

Fix: keep the tokens in the Keychain (a `kSecClassGenericPassword` item per token, or one
item holding the session blob), read the existing UserDefaults values once and migrate
them, then stop writing tokens there.

Why it is not done here: the app builds unsigned by design, and an unsigned binary's
Keychain items are tied to a signature that changes on every rebuild, so macOS re-prompts
for access each time. That would turn a rebuild into a system dialog for anyone working on
the app. The migration is worth doing when the app is signed and notarised, or behind a
flag that defaults to off until then.

A test for it belongs with `LogoutPersistenceTests`: a stored UserDefaults token is
migrated to the Keychain once, a second read does not duplicate the item, and logout
removes it.

## The content decryption key is gone

The `AudioDecryption` route unwrapped Tidal's `OLD_AES` key id with a master key that is
published in third-party Tidal clients and therefore public. That route was removed on
2026-10-08: the app now streams Tidal's openapi HLS manifest, which its desktop-client
session is answered with no key line, so nothing is decrypted and no published key is used.

What it means now: the app plays the stream Tidal hands it through AVFoundation's own
path, so the DRM-circumvention question this section carried no longer applies.
