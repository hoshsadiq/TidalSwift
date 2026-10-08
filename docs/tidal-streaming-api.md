# Tidal Streaming API: Qualities, Dolby Atmos and DRM

Findings from probing Tidal's playback endpoints (September 2026) with TidalSwift's own client ID and a capture of the official iOS app, plus what TidalSwift implements and the plan for the remaining qualities.

All tests used a premium account in Germany (`countryCode=DE`). Reference tracks:

| Track | ID | Audio modes | Tags |
|---|---|---|---|
| The Weeknd – Blinding Lights | 125155092 | `DOLBY_ATMOS` only | `DOLBY_ATMOS` |
| Matt Johnson – Blinding Lights | 188600501 | `STEREO`, `DOLBY_ATMOS` | |
| Daft Punk – Get Lucky | 19823990 | `STEREO` | `LOSSLESS`, `HIRES_LOSSLESS` |

## Quality tiers

Tidal's current tiers and their API values:

| Tidal name | API value | `AudioQuality` case | Format |
|---|---|---|---|
| Low (96 kbps) | `LOW` | `.low` | HE-AAC (`mp4a.40.5`) |
| Low (320 kbps) | `HIGH` | `.medium` | AAC-LC (`mp4a.40.2`) |
| High | `LOSSLESS` | `.high` | FLAC 16 bit / 44.1 kHz |
| Max | `HI_RES_LOSSLESS` | `.max` (commented out) | FLAC up to 24 bit / 192 kHz |
| Dolby Atmos | audio mode `DOLBY_ATMOS` | – | E-AC-3 JOC, 768 kbps |

Tracks never report `HI_RES_LOSSLESS` as their `audioQuality` in the v1 API; the maximum there is `LOSSLESS`. Hi-Res availability only shows up in `mediaMetadata.tags` (`HIRES_LOSSLESS`). Subscriptions and some other objects still send `HI_RES_LOSSLESS`, so `AudioQuality` decodes it as `.high` instead of failing.

## Endpoints

### v1 `GET /tracks/{id}/streamUrl` (legacy, used for stereo)

Parameter `soundQuality`.

| Quality | Result |
|---|---|
| `LOW`, `HIGH` | 401 `subStatus 4005` "Asset is not ready for playback" |
| `LOSSLESS` | Direct FLAC URL, 16/44.1 |
| `HI_RES_LOSSLESS` | Same as `LOSSLESS` |
| Atmos-only tracks | 401 `subStatus 4005` |

`/tracks/{id}/offlineUrl` returns 404 for every quality and track, so TidalSwift no longer offers it.

### v1 `GET /tracks/{id}/playbackinfopostpaywall`

Parameters: `audioquality`, `playbackmode`, `assetpresentation=FULL`, optionally `immersiveaudio`.

| Request | Result |
|---|---|
| `LOW`, `HIGH` | DASH manifest, AAC, `cenc` encrypted with Widevine (`edef8ba9-…`) and PlayReady (`9a04f079-…`) |
| `LOSSLESS`, `HI_RES_LOSSLESS` | BTS manifest (`application/vnd.tidal.bts`), direct FLAC URL, 16/44.1, `encryptionType: NONE` |
| Track with Atmos, any quality | BTS manifest, `eac3`, `encryptionType: NONE`, `audioMode: DOLBY_ATMOS` |
| Track with stereo and Atmos, `immersiveaudio=false` | Stereo FLAC |
| `playbackmode=OFFLINE` for Atmos | 401 `subStatus 4005` |

- Tracks with both modes return **Atmos by default**. Only `immersiveaudio=false` forces stereo; `audiomode=STEREO` has no effect.
- Adding the iOS app's parameters (`deviceType=PHONE`, `platform=IOS`, `locale`) changes nothing.
- The Atmos file is a 5.1-bed E-AC-3 JOC stream in MP4. `afinfo` lists the Atmos (`ec+3`) layouts up to 9.1.6, `ffprobe` reports "Dolby Digital Plus + Dolby Atmos", and `AVPlayer` plays it from a local file.

### openapi `GET https://openapi.tidal.com/v2/trackManifests/{id}`

Parameters: `manifestType` (`HLS` or `MPEG_DASH`), `formats` (repeated: `HEAACV1`, `AACLC`, `FLAC`, `FLAC_HIRES`, `EAC3_JOC`), `uriScheme` (`HTTPS` or `DATA`), `usage=PLAYBACK`, `adaptive=true`. Header `Accept: application/vnd.api+json`. Accepts the same bearer token as v1; an expired token gives 401 with a JSON:API error (`"detail": "Expired token"`).

The master playlist only lists the requested `formats`: `FLAC` plus `FLAC_HIRES` gives exactly the two FLAC variants.

| Request | Result |
|---|---|
| `manifestType=HLS` | HLS master playlist, see below |
| `manifestType=MPEG_DASH` | DASH with Widevine, license at `api.tidal.com/v2/widevine` |
| `formats=EAC3_JOC` | Served: a master playlist naming an `E-AC-3 JOC` variant |

**Corrected 2026-10-08.** An earlier version of this table said `formats=EAC3_JOC` is refused with 403 `CLIENT_NOT_ENTITLED`. Measured again with this app's desktop-client session and no `X-Tidal-Token`, `EAC3_JOC` is **served**: the master playlist names an E-AC-3 JOC variant, so the Atmos rendition is reachable through the manifest API, not only through v1.

The response's `attributes` also contain `drmData` (`drmSystem: FAIRPLAY`, `licenseUrl: https://fp.fa.tidal.com/license`, `certificateUrl: https://fp.fa.tidal.com/certificate`, `initData: ["skd://…"]`) and ReplayGain data for album and track.

The HLS master playlist for Get Lucky:

```
#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://…",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
#EXT-X-STREAM-INF:BANDWIDTH=113395,AVERAGE-BANDWIDTH=97245,CODECS="mp4a.40.5"      → Low 96
#EXT-X-STREAM-INF:BANDWIDTH=383236,AVERAGE-BANDWIDTH=322651,CODECS="mp4a.40.2"     → Low 320
#EXT-X-STREAM-INF:BANDWIDTH=1066740,AVERAGE-BANDWIDTH=944861,CODECS="fLaC"         → FLAC 16 bit / 44.1 kHz
#EXT-X-STREAM-INF:BANDWIDTH=1772645,AVERAGE-BANDWIDTH=1638279,CODECS="fLaC"        → FLAC 24 bit / 44.1 kHz
```

Variant playlists (on `im-fa.manifest.tidal.com`) are VOD fMP4 with 4-second segments on `sp-ad-fa.audio.tidal.com`, an `EXT-X-MAP` init segment and `EXT-X-KEY` with the same `skd://` URI. All playlist and segment URLs carry a time-limited `token` parameter, so manifests have to be fetched shortly before playback. Segment URLs also carry an `info` parameter, base64 for `PLAYBACK,<track ID>,3003,<user ID>`. The init segments aren't encrypted, so the FLAC `STREAMINFO` in `dfLa` shows the real bit depth and sample rate. The samples are `cbcs` encrypted.

**Superseded (2026-10-08).** This is no longer the only path found: the same endpoint answers this app's desktop-client session unencrypted at 24 bit (see the HLS route below), so the FairPlay route is not required for Hi-Res.

## Official iOS app (HTTP Catcher capture)

Capture of TIDAL for iOS (build 9217, client version 2.216.0) playing three songs:

- Audio: FLAC in fMP4 from `sp-ad-fa.audio.tidal.com`, sample entry `enca`, scheme `cbcs`, all three songs at 16 bit / 44.1 kHz.
- DRM: `GET fp.fa.tidal.com/certificate` once, without `Authorization`, then `POST fp.fa.tidal.com/license` per track with `Content-Type: application/octet-stream`, `Authorization` and an `x-tidal-streaming-session-id` (a UUID per playback). Request bodies were 6.8–9.5 KB.
- The manifest request itself sat in `CONNECT` tunnels to `api.tidal.com` and `openapi.tidal.com` that the capture didn't decrypt. The openapi `trackManifests` endpoint above matches what the app plays.
- API calls carry `deviceType=PHONE&platform=IOS&locale=de` and the headers `x-tidal-client-version` and `x-tidal-token`.

## Official macOS client (asar + cached web bundle, measured 2026-10-08)

The installed `TIDAL.app` is an Electron shell (client `desktop@2026.09.30`) whose UI is a web page
the shell loads from `desktop.tidal.com`; the asar holds only the main process. Read from the
extracted asar and the service worker's cached web bundle:

- **Audio quality is a three-option radiogroup plus a separate switch**: Low (with an inner
  96 / 320 kbps selector), High (`16-bit, 44.1 kHz`, sends `LOSSLESS`) and Max (`Up to 24-bit,
  192 kHz`, sends `HI_RES_LOSSLESS`), plus **Adaptive streaming** (`Automatically adjust audio
  quality based on your network conditions`). The default streaming quality is `HI_RES_LOSSLESS`.
- **No Atmos preference exists.** Atmos is per-track metadata and a badge (`Dolby Atmos`) drawn
  from `mediaMetadata.tags`. The quality badge deliberately yields nothing for an Atmos-only or
  Sony-360-only track, so the two badges are mutually exclusive by construction. The leftovers of
  a removed toggle still ship — a `settings_dolby_atmos_toggle_description` locale key, a
  `dolbyAtmosDialogShown` storage key and a `modal/SHOW_DOLBY_ATMOS` action, none rendered or
  dispatched.
- **The native player never names a mode.** It calls
  `GET /v1/tracks/{id}/playbackinfo?audioquality=<quality>&playbackmode=STREAM&assetpresentation=FULL`
  with the client id and the `Bearer` token, and reads `audioMode` / `audioQuality` back out as
  `actualAudioMode` / `actualAudioQuality`: the server tells the client which rendition it got. The
  Tidal Connect path pins `audiomode: STEREO`.
- **The web player hardcodes stereo.** It calls openapi
  `GET /trackManifests/{id}?adaptive=&formats=<ladder>&manifestType=HLS|MPEG_DASH&uriScheme=DATA&usage=PLAYBACK`
  with a format ladder derived from the quality, and stores `audioMode: 'STEREO'` in the playback
  info it builds, with `bitDepth: 0` and `sampleRate: 0` placeholders — the same no-bit-depth
  finding this app has for FLAC in fMP4.

Upstream models quality as a ceiling expressed in `audioquality` terms and Atmos as something the
service hands you, surfaced as an icon; there is no cross-preference to order. This app's Atmos
switch is therefore our own addition, not parity, and it can only order a rung the ceiling already
admits — which is why the ceiling gates it (see the rungs below).

## State in TidalSwift

On `main`:

- **Offline files** are recognized regardless of extension (FLAC files were previously never counted as offline) and looked up by the offline quality instead of the streaming quality.
- **Removed:** the quality picker at login, which only set the streaming quality.

On branch `Dolby-Atmos`:

- **Dolby Atmos playback and download** through `playbackinfopostpaywall` (BTS, E-AC-3, unencrypted, always `playbackmode=STREAM`). Used when "Prefer Dolby Atmos for streaming" is on (Stream → Quality) or when a track has no stereo version. Downloads get `.m4a`.
- **Availability:** tracks with an Atmos mode are playable; only Sony 360 Reality Audio–only tracks count as unavailable.
- **Quality menu:** only "High (Lossless)" plus the Atmos toggle. Low 96, Low 320 and Max are commented out with the reason.
- **Top bar:** `LOW 96`, `LOW 320`, `HIGH`, `MAX`, `ATMOS`. The maximum shows `MAX` from the Hi-Res tag and appends `· ATMOS`.
- **Offline sync:** stays stereo FLAC; Atmos only for Atmos-only tracks.
- **Removed:** the offline URL type (`offlineUrl` returns 404).

## FairPlay HLS playback (for other clients)

The openapi HLS manifest is what this app streams now. For this app's desktop-client session it carries no key line at all, so nothing below is needed here. A device-client session is answered a manifest with `drmData` and an `EXT-X-SESSION-KEY`, and the steps are what such a client needs; they are kept as reference for other clients, not as a plan for this app.

### Scope and limits

- **Only a DRM-wrapped manifest needs this.** For a manifest with a key line, the content stays encrypted and the keys are handled by the system's protected playback path, so the client never sees decrypted audio. A manifest with no key line, which is what this app gets, needs none of it.
- Atmos arrives through the manifest API too: `formats=EAC3_JOC` is served to this app's session (measured 2026-10-08), so the Atmos rendition is an HLS rung as well as the v1 `playbackinfopostpaywall` rendition.

### What a FairPlay client needs

1. **Choose the quality.** Request only the wanted format in `formats` (e.g. only `FLAC_HIRES` for Max), so `AVPlayer` doesn't switch variants on its own.
2. **Create a key session.** An `AVContentKeySession` for FairPlay Streaming, with the `AVURLAsset` added as recipient.
3. **Answer a key request.** Load the certificate from `certificateUrl` (no `Authorization` needed; cache it per session), take the content identifier from the `skd://` URI, and create the SPC with `makeStreamingContentKeyRequestData`.
4. **Post the SPC.** `POST` it as `application/octet-stream` to `licenseUrl` with `Authorization` and a fresh `x-tidal-streaming-session-id`, then pass the response back as `AVContentKeyResponse(fairPlayStreamingKeyResponseData:)`.

### Open questions

- Does the license server accept a third-party client ID?
- Does the license response need to be unwrapped (e.g. JSON or base64) or is it the raw CKC?
- Is `x-tidal-streaming-session-id` required, and does it tie into playback reporting?
- Does HLS playback count as a stream that stops playback on other official clients of the same account?

## Independent re-check (2026-10-04)

Re-probed the endpoints above on 2026-10-04 with a US premium account, a different account from the September run. `/users/{id}/subscription` reports `highestSoundQuality: LOSSLESS`. Requests carried `Authorization`, `X-Tidal-Token` and the desktop TIDAL user agent, with `countryCode=US&deviceType=BROWSER&platform=WEB&locale=en_US`. The probe is reproducible from `.omo/scripts/probe-endpoints.sh`, which reads the session out of TidalSwift's own preferences and never prints tokens or full stream URLs.

| Request | Result |
|---|---|
| `streamUrl`, `HI_RES_LOSSLESS` / `LOSSLESS` | 200, direct FLAC URL |
| `streamUrl`, `HIGH` / `LOW` | 401 `subStatus 4005` "Asset is not ready for playback" |
| `playbackinfopostpaywall`, `HI_RES_LOSSLESS` / `LOSSLESS` | `application/vnd.tidal.bts`, `encryptionType: NONE`, one URL; both decode to an identical file (FLAC 44100 Hz, 16 bit, 958278 bps) |
| `playbackinfopostpaywall`, `HIGH` / `LOW` | `application/dash+xml` |
| `offlineUrl`, every quality | 404 `subStatus 2001` "Resource not found" |
| Atmos-only track, post-paywall | unencrypted E-AC-3 BTS manifest, played by `AVPlayer`; no stereo rendition |

The conclusion for these v1 endpoints stands: asking for `HI_RES_LOSSLESS` here does not unlock true hi-res. Tidal silently downgrades the request to the lossless stream instead of refusing it, and returns byte-identical audio, so no client-side flag can unlock Max on this path. `offlineUrl` is dead for every quality. On the v1 endpoints Atmos stays a separate rendition: a track with only `DOLBY_ATMOS` has no `streamUrl` stereo fallback, and its post-paywall response is a playable E-AC-3 stream. (The manifest API is different — it serves that same track stereo FLAC as well as `EAC3_JOC`; see the 2026-10-08 measurement below.)

## The desktop host serves more, to the right session (measured 2026-10-05)

The same request against `https://desktop.tidal.com/v1/tracks/{id}/playbackinfo` behaves differently, including for tracks the v1 host refuses:

| Session | `HI_RES_LOSSLESS` | `LOSSLESS` | `HIGH` / `LOW` |
|---|---|---|---|
| This app's device-code token (`cid` 3003, no `cuk`) | `DOLBY_ATMOS`, E-AC-3, `NONE` | `DOLBY_ATMOS` | audio DASH |
| The official desktop app's token (`cid` 7785, `cuk` present) | `STEREO`, **24 Bit**, FLAC, `OLD_AES` | `STEREO`, 16 Bit, FLAC, `OLD_AES` | audio DASH |

So the rendition is decided by the session, not by the request: identical calls with identical headers return Atmos or stereo depending only on which client the token belongs to. Same account in both cases, so it is not a subscription difference.

The `OLD_AES` payload is AES-128-CTR encrypted, with the key wrapped in the manifest's `keyId` (64 bytes: a 16-byte IV, then the wrapped key and nonce). Unwrapping used a publicly documented AES-256-CBC key; the deleted `AudioDecryption` implemented both steps. Verified end to end: a 31,246,448-byte download decrypts to a file ffprobe reads as `flac, 44100 Hz, 2 ch, 24-bit, 1,116,554 bps`.

The `HIGH` / `LOW` DASH manifest is documented as `cenc` by its namespace alone; it carries no `ContentProtection`, no `pssh`, no `senc`, and no `sinf`. The segments are plain fragmented AAC and played once assembled (the deleted `DashAudio`). The `cenc` declaration is vestigial.

The `cuk` claim is necessary for the desktop client's session but not sufficient on its own. It arrives when the login sends `client_unique_key` on both the authorize request and the token exchange, as the official app does, and our login now does that (`DesktopLogin`). It does not make a session the desktop client: a device-code session (`cid` 3003) that sent `client_unique_key` on both requests carried a `cuk` claim, and the same `playbackinfo` call still answered `LOW` / `DOLBY_ATMOS`. The client id decides, as the 2026-10-06 section below measures.

## The client identity is what gates playback, not the `cuk` (measured 2026-10-06)

The paragraph above claimed `cuk` marks a session as the desktop client. Four combinations of token and `X-Tidal-Token` header say otherwise. One request, `https://desktop.tidal.com/v1/tracks/433645363/playbackinfo?audioquality=HI_RES_LOSSLESS&playbackmode=STREAM&assetpresentation=FULL&deviceType=BROWSER&platform=WEB&locale=en_US&countryCode=US`, same account throughout:

| Token | `X-Tidal-Token` | Answer |
|---|---|---|
| device client (`cid` 3003), fresh `cuk` in the token | device client | `LOW`, `DOLBY_ATMOS` |
| device client (`cid` 3003), fresh `cuk` in the token | desktop client | `LOW`, `DOLBY_ATMOS` |
| desktop client (`cid` 7785) | device client | `STEREO`, 24 Bit, FLAC |
| desktop client (`cid` 7785) | desktop client | `STEREO`, 24 Bit, FLAC |

The header makes no difference. The client the token belongs to decides, and `cuk` alone does not move a session up: the device token carried one and was still answered two tiers below the account's own `LOSSLESS` cap, silently rather than with an error.

The `redirect_uri` is fixed for the same reason. It has to match a value registered for the client, and the token exchange sends it again, so it cannot be chosen freely. Authorizing the desktop client with `redirect_uri=tidal-swift://login/auth` is refused: the browser shows "Something went wrong. Please try again." and no code is issued. Changing it back to `tidal://login/auth` works. A client of our own could own a scheme like `tidal-swift://`, but that client is not the desktop client, and by the table above it would not be served 24 Bit over this endpoint. Owning the login scheme and keeping hi-res stereo through the v1 host are mutually exclusive.

## The openapi manifest carries no DRM for this app's session (measured 2026-10-06)

The openapi section above, and the "Official iOS app" capture under it, describe the HLS manifest with `#EXT-X-SESSION-KEY` and `drmData`. That is what a phone-client session receives. This app's own desktop-client session receives the same playlist with no key line at all, which is why the plan below is heavier than it needs to be for us.

Request, with this app's token and no `X-Tidal-Token` or `client_unique_key`:

```
GET https://openapi.tidal.com/v2/trackManifests/{id}
    ?manifestType=HLS&uriScheme=HTTPS&usage=PLAYBACK
    &formats=FLAC_HIRES,FLAC,AACLC,HEAACV1&adaptive=true
```

`adaptive=true` is required, and without it the endpoint answers 400 `MISSING_REQUIRED_PARAMETER`. Enum values are upper case (`uriScheme=DATA` or `HTTPS`, `usage=PLAYBACK`, `formats=FLAC_HIRES`); lower case is rejected, `flacHires` with `INVALID_VALUE_TYPE` and `playback` with `INVALID_ENUM_VALUE`.

`attributes.formats` lists every tier that was asked for, `attributes.drmData` is absent, and `attributes.uri` is a master playlist on `im-fa.manifest.tidal.com` with four variants for a 24 Bit track:

| Variant | Codec | Bandwidth |
|---|---|---|
| 96 kbps | `mp4a.40.5` | 98,183 |
| 320 kbps | `mp4a.40.2` | 324,274 |
| Lossless | `fLaC` | 889,723 |
| Max | `fLaC` | 1,596,037 |

That playlist contains no `EXT-X-KEY` and no `EXT-X-SESSION-KEY` line, so the segments are not encrypted and no FairPlay step is involved. A standalone AVFoundation program confirmed it: AVPlayer loads the master playlist and plays the highest variant directly, the audio track reports codec `flac` at 44,100 Hz with 2 channels, and a seek to 200 s landed at 202.6 s and carried on playing. Nothing is downloaded, decrypted or cached by us for that to work.

The same request with a device-client token is answered differently: `drmData` with `drmSystem: FAIRPLAY`, `licenseUrl: https://fp.fa.tidal.com/license`, `certificateUrl: https://fp.fa.tidal.com/certificate`, and a `SAMPLE-AES` session key using `com.apple.streamingkeydelivery`. That is the case the plan below and the SDK's `FairPlayLicenseFetcher` handle, with the certificate fetched once and a server playback context posted per track.

What this means for this app: streaming needs none of the old machinery. As of 2026-10-08 the app streams the manifest directly and downloads the same manifest for the cache and for the offline library, so the decrypt, the DASH assembly and the whole-file-before-play step are gone; see "The HLS route as implemented" below.

Two smaller consequences to settle when it is: the quality badge cannot read bit depth from a FLAC-in-fMP4 format description (`bitsPerChannel` comes back 0), so it would have to label from the chosen variant rather than from the decoded file; and TIDAL's developer documentation still states that the SDK's Player module is the only allowed way for third parties to play TIDAL content, which is a compliance question rather than a technical one.

## The HLS route as implemented (2026-10-08)

A play, a prefetch and an offline download all resolve the same openapi manifest and, when a file is wanted, download the variant it names and concatenate the initialization segment with the media segments into one fMP4. `HLSStreaming` is the client, and each rung names one format, so the playlist holds exactly that variant: `FLAC_HIRES` (Max), `FLAC` (Lossless), `AACLC` (320 kbps), `HEAACV1` (96 kbps) and `EAC3_JOC` (Dolby Atmos).

**Route order for a play** (`PlaybackRoutingPolicy.routes`, first route that produces a stream wins):

| track / session | routes |
| --- | --- |
| session with the desktop `cuk` claim | `hls`, then `directStream` |
| session without it | `directStream` |

HLS is gated only on the desktop session. It used to be gated on an advertised stereo rendition too, which was wrong: the catalogue omits `STEREO` for tracks the manifest API still serves FLAC for (measured 2026-10-08), so an Atmos-advertised track that has no advertised stereo was dropped to `directStream`, and the v1 `streamUrl` refuses those tracks with 401 `subStatus 4005`. Such a track now resolves and plays through HLS.

**The rungs** (`HLSStreaming.rungs`) are the chosen stereo tier walking down, with the Atmos rung ordered by the preference. The ceiling gates the Atmos rung: only High and Max admit it, so a Low or Medium ceiling walks the stereo ladder alone and never plays the ~768 kbps E-AC-3 stream (`AudioQuality.admitsDolbyAtmos`, decided 2026-10-08).

| ceiling | preference | rungs (track advertises Atmos) |
| --- | --- | --- |
| Max | on | `EAC3_JOC`, then `FLAC_HIRES`, `FLAC`, `AACLC`, `HEAACV1` |
| Max | off | `FLAC_HIRES`, `FLAC`, `AACLC`, `HEAACV1`, then `EAC3_JOC` |
| High | on | `EAC3_JOC`, then `FLAC`, `AACLC`, `HEAACV1` |
| High | off | `FLAC`, `AACLC`, `HEAACV1`, then `EAC3_JOC` |
| Low / Medium | on or off | the stereo tiers only |
| any, track does not advertise Atmos | any | the stereo tiers only |

The preference chooses the order, it never removes a rung, so an Atmos-only track plays either way — except under a Low or Medium ceiling, where Atmos is not asked at all. The `directStream` fallback stays last: it is the v1 `streamUrl` ladder with the Atmos rendition on `playbackinfopostpaywall`, and is reached only when every HLS rung is refused.

**Measured 2026-10-08 (track 241,647,167, the developer's “The Show Goes On”).** The catalogue carries two entries for this track, both `audioModes: [DOLBY_ATMOS]` and no `STEREO`, yet:

| endpoint | result |
| --- | --- |
| v1 `streamUrl`, every quality | 401 `subStatus 4005` "Asset is not ready for playback" — the route that refuses it |
| v1 `playbackinfopostpaywall` with this app's headers | nothing usable |
| manifest `FLAC_HIRES` | refused `CLIENT_NOT_ENTITLED` |
| manifest `FLAC` / `AACLC` / `HEAACV1` | served — stereo exists |
| manifest `EAC3_JOC` | served — Atmos exists |

Two conclusions. `audioModes` is not a stereo test: the catalogue omits `STEREO` while the manifest API serves FLAC stereo, so gating HLS on the advertised modes broke every track shaped like this. And Atmos comes through the manifest API: `EAC3_JOC` is served, not refused, so Atmos is an HLS rung and the old claim that only the v1 post-paywall endpoint serves Atmos is out of date. Live probes confirm it: with the preference off this track serves `FLAC` (badge `16-bit`), with the preference on it serves `EAC3_JOC` (badge `Dolby Atmos`), and playback advances in both cases; the stereo entry `5,872,412` serves `FLAC` with the preference off.

**Stream, cache behind the play, prefetch ahead.** A play streams the playlist at once, so there is no download before it starts; the same playlist is written into the cache by a detached task behind the play. The prefetcher prepares the upcoming tracks through that same write, so a prefetched track is exactly a cached track and the next play reads the file with no manifest request. The cache lives at `~/Library/Caches/TidalSwift/stream/<trackId>-<tier>.m4a`, where `<tier>` is the served rung's `AudioQuality` raw value (`HI_RES_LOSSLESS`/`LOSSLESS`/`HIGH`/`LOW`, or `DOLBY_ATMOS`), so a Max request answered with the 16-bit file lands as `<trackId>-LOSSLESS.m4a` (`HLSRung.fileMarker`). Files are kept until the configured limit, pruned by the LRU in `PlaybackCacheEviction`: files untouched for a week are dropped, then the least recently used until under the budget, evicting down to 80% of it. The track playing now, the prefetch window and anything mid-download are protected. The prune enumerates only the cache directory and never reaches the offline library under `~/Music`.

**Offline** downloads the same manifest to `<trackId>.<quality>.m4a` in `~/Music/TidalSwift Offline Library`, and the served rung names the file: a stereo tier by its quality, the Atmos `EAC3_JOC` rung as `<trackId>.atmos.m4a`. An Atmos-advertised track with the preference on asks the Atmos rung first and stores the Atmos file at a High or Max ceiling; below that the Atmos rung is not on the ladder at all, so the stereo ladder is asked alone. A stored file is served only when its rendition is admitted by both the play ceiling and the offline ceiling, so an Atmos file stops playing when either setting drops below High, and the file stays on disk until a replacement resolves. With the preference off the stereo ladder is asked first and the Atmos rung is the fallback where the ceiling admits it. A direct-stream fallback file is named for the tier that path serves, so a `HI_RES_LOSSLESS` request the endpoint answers with the 16-bit lossless file lands as `<trackId>.lossless.m4a`.

A plain sync accepts any tier the ceiling's ladder can serve, so a stepped-down file (e.g. `FLAC_HIRES` refused, `FLAC` stored) is kept rather than re-resolved on every pass — the per-sync upgrade probe was dropped by decision (2026-10-08). A settings change (the quality or the Atmos preference) re-checks every file against the new wish and replaces the ones it no longer wants, except where the source already resolves to the variant on disk, which is kept as it is; and when nothing resolves at all, the rejected file is kept and the wish stays, so the next sync retries the replacement rather than accepting the old tier for good. When more than one file is present the choice is deterministic: the wanted variant, then the best tier on the ceiling's ladder, then the file name. The offline library was empty when this landed, so no migration was needed.

**The quality setting is a ceiling, not an exact tier.** The fetch starts where the setting points and walks down until Tidal serves something, so a track with no hi-res master still plays. Atmos is outside that ladder and is only requested when the setting is High or Max; a Low or Medium ceiling also refuses an Atmos answer the v1 endpoint returns anyway, so a track Tidal serves no stereo rendition for is skipped below that rather than played as Atmos. Measured against the official macOS client: it asks for `HI_RES_LOSSLESS` and is answered `audioMode: STEREO` for a track the catalogue badges `DOLBY_ATMOS`, plays that stereo version, and never requests Atmos at all (`.omo/evidence/upstream-merge/tidal-app-probe.md`). The catalogue's `audioModes` describes what Tidal holds, not what any client plays.

**Quality badge.** FLAC in fMP4 reports `bitsPerChannel` as 0, so the badge is read from the served rung (`HLSStreaming.badge(for:sampleRate:)`): 24-bit for `FLAC_HIRES`, 16-bit for `FLAC`, 320 kbps for `AACLC`, 96 kbps for `HEAACV1`, and `Dolby Atmos` for `EAC3_JOC`. The sample rate is appended when the stream reports one: a cached file reads it, and a streamed one has it filled from the item's own `tracks` once the item loads. An offline file's badge reads the tier its name carries, not the track's advertised quality, so a 24-bit offline file on a `LOSSLESS`-advertised track reads 24-bit rather than 16-bit.

**Deleted** (see `.omo/evidence/upstream-merge/hls-stage4.md`): `AudioDecryption` and its suite, `DashAudio` and its suite, the `hiResStereo` and `dash` routes with `Session.hiResStereoStream`, `Session.dashAudioManifest`, the `OLD_AES` manifest policy and the download-and-decrypt path. The type `HiResStreamCache` became `PlaybackCache`, `HiResStreamingPreferences` became `PlaybackCachePreferences`, and `HiResStreaming.swift` became `PlaybackRouting.swift` and `PlaybackCache.swift`.
