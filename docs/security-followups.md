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

## The content decryption key is a public constant

`AudioDecryption` unwraps Tidal's `OLD_AES` key id with a master key that is published in
third-party Tidal clients and therefore public. This is not a leak in this repository, and
there is no secret to move: the route to 24-bit stereo depends on it.

The honest statement of what it means: the app decrypts Tidal's content encryption with a
key that is not secret, and anyone with a login can do the same. What it does not do is
break the account's authentication or reach anything the account cannot already stream.
