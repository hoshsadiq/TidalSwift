<img src="README.assets/Icon.png" alt="Icon" width="128">

# TidalSwift

Tidal Music Streaming Client & Library written in Swift

[![CI](https://github.com/hoshsadiq/TidalSwift/actions/workflows/ci.yml/badge.svg)](https://github.com/hoshsadiq/TidalSwift/actions/workflows/ci.yml)
[![Pre-commit](https://github.com/hoshsadiq/TidalSwift/actions/workflows/pre-commit.yml/badge.svg)](https://github.com/hoshsadiq/TidalSwift/actions/workflows/pre-commit.yml)
[![CodeQL](https://github.com/hoshsadiq/TidalSwift/actions/workflows/codeql.yml/badge.svg)](https://github.com/hoshsadiq/TidalSwift/actions/workflows/codeql.yml)
[![Release](https://github.com/hoshsadiq/TidalSwift/actions/workflows/release.yml/badge.svg)](https://github.com/hoshsadiq/TidalSwift/actions/workflows/release.yml)

It supports all major features of the official Tidal app, while adding additional ones, like Lyrics, automatic Dark Mode, Downloads & Offline Playback – all while being only 1/10th the size of the official app.

This is a fork of the original [TidalSwift](https://github.com/melgu/TidalSwift) by Melvin Gundlach, maintained by [Hosh Sadiq](https://github.com/hoshsadiq).

## Download

You can download the latest version [here](https://github.com/hoshsadiq/TidalSwift/releases).
After downloading and unpacking the TidalSwift.zip, move the app to the Applications folder. The app is unsigned, so macOS will block it on first launch. You can allow it in System Settings → Privacy & Security, or run this command:

```sh
xattr -d com.apple.quarantine /Applications/TidalSwift.app
```

## Audio quality

Playback goes through Tidal's own playback service, the one the desktop app calls. The app logs in as the desktop client, and that is what makes the stereo renditions available at every tier; a session Tidal does not recognise is served Dolby Atmos instead. Tidal answers that at any quality, but the app only plays Atmos at High or Max: below that such a track is skipped rather than played.

Preferences → Quality sets the tier:

- **Low:** 96 kbps AAC.
- **Medium:** 320 kbps AAC where Tidal serves it.
- **High:** 16-bit FLAC at 44.1 kHz.
- **Max:** up to 24-bit FLAC.

When Tidal serves no stereo rendition for a track, the app falls back to the older direct stream, or to Dolby Atmos at High or Max.

Dolby Atmos is a preference rather than a tier, and offline keeps its own copy of it. It only applies at High or Max quality: below that the Atmos rendition is never requested, and a track with no other version is skipped. At High or Max, a track with an Atmos version plays Atmos when the preference is on; with it off you get the stereo rendition, and the Atmos one is only used when the ceiling allows it and the track has nothing else.

The same pane holds "Ignore subscription limits", which lets you pick a tier above your subscription even when Tidal may refuse it, "Prefetch tracks", the number prepared ahead of the one playing (0 to 15, default 3), and "Cache size", the space prepared tracks may use in GB (default 2). Prepared tracks live in `~/Library/Caches/TidalSwift/`, so they start instantly.

## Impressions

### Lyrics

Also, unlike the official app, it can display the Lyrics of the currently playing song.

<img src="README.assets/Lyrics.png" alt="Lyrics" width="400">

### Offline

Unlike the official desktop app, TidalSwift supports offline playback. Downloaded albums, tracks and playlists appear in Collection alongside your favourites, and a "Downloaded only" toggle filters the list down to them. Items that are available offline show a cloud badge.

Downloads follow the Download quality setting, including its own Dolby Atmos setting. Logging out leaves the downloaded music in place; only the option in the logout dialog removes it.

### Downloads

It even goes a step further. You can download music to your hard drive and do with it whatever you want.

<img src="README.assets/Downloads.png" alt="Context Menu: Download highlighted" width="180">

### Search

![Search](README.assets/Search.png)

### Favorites

![Playlists](README.assets/Playlists.png)

![Albums](README.assets/Albums.png)

![Tracks](README.assets/Tracks.png)

![Videos](README.assets/Videos.png)

![Artists](README.assets/Artists.png)

### Detail Views

![Album View](README.assets/AlbumView.png)

![Artist View](README.assets/ArtistView.png)

### Login

Log in through the desktop-client flow: the app opens Tidal in your browser and waits for the `tidal://` callback. This is the preferred path because its session is the one Tidal serves the lossless and hi-res stereo renditions to. The device-code flow works as a fallback, and there is a manual refresh-token option as well.

![Login](README.assets/Login.png)

### Credits

<img src="README.assets/Credits.png" alt="Credits" width="400">

### Dark Mode

TidalSwift obviously supports the macOS Dark Mode.

![Artist View (Dark Mode)](README.assets/ArtistView-DarkMode.png)
