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
| `manifestType=HLS` | FairPlay HLS master playlist, see below |
| `manifestType=MPEG_DASH` | DASH with Widevine, license at `api.tidal.com/v2/widevine` |
| `formats=EAC3_JOC` | 403 `CLIENT_NOT_ENTITLED` |

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

**This is the only path found that delivers Hi-Res (24 bit) to TidalSwift's client ID.**

## Official iOS app (HTTP Catcher capture)

Capture of TIDAL for iOS (build 9217, client version 2.216.0) playing three songs:

- Audio: FLAC in fMP4 from `sp-ad-fa.audio.tidal.com`, sample entry `enca`, scheme `cbcs`, all three songs at 16 bit / 44.1 kHz.
- DRM: `GET fp.fa.tidal.com/certificate` once, without `Authorization`, then `POST fp.fa.tidal.com/license` per track with `Content-Type: application/octet-stream`, `Authorization` and an `x-tidal-streaming-session-id` (a UUID per playback). Request bodies were 6.8–9.5 KB.
- The manifest request itself sat in `CONNECT` tunnels to `api.tidal.com` and `openapi.tidal.com` that the capture didn't decrypt. The openapi `trackManifests` endpoint above matches what the app plays.
- API calls carry `deviceType=PHONE&platform=IOS&locale=de` and the headers `x-tidal-client-version` and `x-tidal-token`.

## State in TidalSwift

On `main`:

- **Offline files** are recognized regardless of extension (FLAC files were previously never counted as offline) and looked up by the offline quality instead of the streaming quality.
- **Removed:** the quality picker at login, which only set the streaming quality.

On branch `Dolby-Atmos`:

- **Dolby Atmos playback and download** through `playbackinfopostpaywall` (BTS, E-AC-3, unencrypted, always `playbackmode=STREAM`). Used when "Prefer Dolby Atmos" is on (Playback → Audio Quality) or when a track has no stereo version. Downloads get `.m4a`.
- **Availability:** tracks with an Atmos mode are playable; only Sony 360 Reality Audio–only tracks count as unavailable.
- **Quality menu:** only "High (Lossless)" plus the Atmos toggle. Low 96, Low 320 and Max are commented out with the reason.
- **Top bar:** `LOW 96`, `LOW 320`, `HIGH`, `MAX`, `ATMOS`. The maximum shows `MAX` from the Hi-Res tag and appends `· ATMOS`.
- **Offline sync:** stays stereo FLAC; Atmos only for Atmos-only tracks.
- **Removed:** the offline URL type (`offlineUrl` returns 404).

## Plan: FairPlay HLS playback

Goal: bring Low 96, Low 320 and Max back for streaming by playing the openapi HLS manifest the way the official app does, through Apple's FairPlay support in AVFoundation.

One measurement changes the shape of this plan: this app's own session receives that playlist with no key line and no `drmData`, so the FairPlay steps are needed by other clients, not by us. See the 2026-10-06 sections at the end.

### Scope and limits

- **Streaming only.** Content stays encrypted. The keys are handled by the system's protected playback path, and TidalSwift never sees decrypted audio. Downloads and offline sync keep using the unencrypted v1 streams (High FLAC and Atmos). Hi-Res, Low 96 and Low 320 can't be downloaded, and decrypting them is out of scope.
- Atmos stays on the v1 path, since openapi refuses `EAC3_JOC` for this client.

### Steps

1. **Prototype the license flow.** This is the main unknown: whether `fp.fa.tidal.com/license` accepts requests from TidalSwift. The SPC can only be created by AVFoundation, so the prototype has to be Swift (a small command-line tool or code in the app), not a script.
   - Fetch `trackManifests` with `manifestType=HLS` and read `uri` and `drmData`.
   - Create an `AVContentKeySession` for FairPlay Streaming and add the `AVURLAsset` as recipient.
   - On a key request: load the certificate from `certificateUrl` (no `Authorization` needed; cache it per session), take the content identifier from the `skd://` URI, and create the SPC with `makeStreamingContentKeyRequestData`.
   - `POST` the SPC as `application/octet-stream` to `licenseUrl` with `Authorization` and a fresh `x-tidal-streaming-session-id`, then pass the response (CKC) back as `AVContentKeyResponse(fairPlayStreamingKeyResponseData:)`.
   - Try the raw SPC first, since the iOS app's body is `application/octet-stream`. If the server rejects it, compare with the capture's request size and headers.
2. **Choose the quality.** Request only the wanted format in `formats` (e.g. only `FLAC_HIRES` for Max), so `AVPlayer` doesn't switch variants on its own. `adaptive=false` might do the same but is untested. Fall back to lower formats when a track lacks the requested one.
3. **Integrate into `Player`.**
   - Add a stream source in TidalSwiftLib next to `audioStream(session:audioQuality:preferDolbyAtmos:)` that returns the HLS URL plus DRM data.
   - Order: offline file → Atmos (v1) → FairPlay HLS for the chosen quality → v1 FLAC as fallback.
   - Keep the key session alive for the player's lifetime, and expire it on logout.
   - Refresh the access token before fetching the manifest (`refreshAccessTokenIfNeeded()`), since openapi rejects expired tokens.
   - Redact `token` and `info` when logging stream URLs; the player prints online URLs in full today.
4. **Menu and labels.** Uncomment Low 96, Low 320 and Max in the menu and the `.max` case in `AudioQuality` (keeping the tolerant decoding). Make sure downloads with those qualities fall back to High instead of failing.
5. **Top bar.** Report the variant that actually plays, e.g. from `AVPlayerItem.accessLog()` or the chosen format, instead of assuming the requested quality.

### Open questions

- Does the license server accept TidalSwift's client ID? The openapi manifest is served to it, which suggests yes, but it's unverified.
- Does the license response need to be unwrapped (e.g. JSON or base64) or is it the raw CKC?
- Is `x-tidal-streaming-session-id` required, and does it tie into playback reporting?
- Do Hi-Res tracks above 48 kHz (e.g. 24/96, 24/192) play cleanly on macOS output devices at their native rate?
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

The conclusion for these v1 endpoints stands: asking for `HI_RES_LOSSLESS` here does not unlock true hi-res. Tidal silently downgrades the request to the lossless stream instead of refusing it, and returns byte-identical audio, so no client-side flag can unlock Max on this path. `offlineUrl` is dead for every quality. Atmos stays a separate rendition: a track with only `DOLBY_ATMOS` has no stereo fallback of its own, and its post-paywall response is a playable E-AC-3 stream.

## The desktop host serves more, to the right session (measured 2026-10-05)

The same request against `https://desktop.tidal.com/v1/tracks/{id}/playbackinfo` behaves differently, including for tracks the v1 host refuses:

| Session | `HI_RES_LOSSLESS` | `LOSSLESS` | `HIGH` / `LOW` |
|---|---|---|---|
| This app's device-code token (`cid` 3003, no `cuk`) | `DOLBY_ATMOS`, E-AC-3, `NONE` | `DOLBY_ATMOS` | audio DASH |
| The official desktop app's token (`cid` 7785, `cuk` present) | `STEREO`, **24 Bit**, FLAC, `OLD_AES` | `STEREO`, 16 Bit, FLAC, `OLD_AES` | audio DASH |

So the rendition is decided by the session, not by the request: identical calls with identical headers return Atmos or stereo depending only on which client the token belongs to. Same account in both cases, so it is not a subscription difference.

The `OLD_AES` payload is AES-128-CTR encrypted, with the key wrapped in the manifest's `keyId` (64 bytes: a 16-byte IV, then the wrapped key and nonce). Unwrapping uses a publicly documented AES-256-CBC key; `AudioDecryption` implements both steps. Verified end to end: a 31,246,448-byte download decrypts to a file ffprobe reads as `flac, 44100 Hz, 2 ch, 24-bit, 1,116,554 bps`.

The `HIGH` / `LOW` DASH manifest is documented as `cenc` by its namespace alone; it carries no `ContentProtection`, no `pssh`, no `senc`, and no `sinf`. The segments are plain fragmented AAC and play once assembled (`DashAudio`). The `cenc` declaration is vestigial.

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

What this means for this app: streaming needs none of the current machinery. The download, the AES-128-CTR decrypt (`AudioDecryption`), the whole-file cache, the prefetch and the DASH assembly (`DashAudio`) exist to serve playback, and for a desktop-client session the endpoint hands over a playlist AVPlayer can play and seek as it is. It is not implemented, and the offline path would still need a route of its own: either Apple's `AVAssetDownloadURLSession` for HLS downloads, or the existing download path kept for offline only.

Two smaller consequences to settle when it is: the quality badge cannot read bit depth from a FLAC-in-fMP4 format description (`bitsPerChannel` comes back 0), so it would have to label from the chosen variant rather than from the decoded file; and TIDAL's developer documentation still states that the SDK's Player module is the only allowed way for third parties to play TIDAL content, which is a compliance question rather than a technical one.
