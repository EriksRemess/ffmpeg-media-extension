# FFmpeg Media Extension

A clean-room macOS MediaExtension that adds Matroska (`.mkv`, `.mka`, `.mks`, `.mk3d`) and WebM (`.webm`) container support to participating AVFoundation applications.

The reader uses FFmpeg 9 `libavformat` for demuxing and passes compressed H.264,
HEVC, AV1, MPEG-4 Video, MPEG-2 Video, AAC, AC-3, E-AC-3, Opus, FLAC, and MP3
samples to Core Media. An FFmpeg-backed `MEVideoDecoder` handles VP9, while DTS
and HE-AAC are decoded to stereo LPCM inside the format reader. Matroska/WebM
color and HDR metadata is preserved; PQ and HLG VP9 decode to 10-bit bi-planar
Core Video buffers instead of being reduced to 8-bit BGRA.

This is an independent, unofficial project. It is not an FFmpeg product and is
not affiliated with or endorsed by the FFmpeg project.

## Install

FFmpeg Media Extension requires an Apple-silicon Mac running macOS 15 or newer.

1. Download `ffmpeg-media-extension-macos-arm64.zip` from the
   [latest release](https://github.com/EriksRemess/ffmpeg-media-extension/releases/latest).
2. Unzip it and move **FFmpeg Media Extension.app** to `/Applications`.
3. Open the app once.
4. Open System Settings → General → Login Items & Extensions. In **By App**,
   click the info button beside FFmpeg Media Extension and enable **Media
   Extensions**.
5. Quit and reopen QuickTime Player.

## Build

Initialize the FFmpeg 9 submodule, then build. The project targets Apple silicon
(`arm64`) only:

```sh
git submodule update --init --depth 1
make
```

The submodule is pinned to the official `n9.0` release tag. Override
`FFMPEG_SOURCE` only when intentionally building against another source tree.

`make` creates an ad-hoc-signed development bundle without changing the
installed extension. `make test` performs a development-signed install,
registers both MediaExtensions, validates the installed bundle, and discovers
`.mkv` and `.webm` test files in `MEDIA_DIR` (default: `$HOME/Movies`). Set
`SHARE_MEDIA_DIR` to include an optional mounted-share directory.

For a development-certificate signature and installation:

```sh
make sign TEAM_ID=YOUR_TEAM_ID SIGN_IDENTITY="Apple Development"
make install TEAM_ID=YOUR_TEAM_ID SIGN_IDENTITY="Apple Development"
```

`make sign` uses `FFmpegMediaExtension.xcodeproj` to ask Xcode for the explicit
macOS development profile required by the restricted format-reader entitlement,
embeds that profile, and signs with its generated entitlements. Set `TEAM_ID`
to your Apple Developer team and sign in to an eligible account in Xcode before
running provisioning or installation targets.

## Architecture

- `FMEFormatReaderFactory` creates one asset reader per file.
- `FMEAsset` adapts `MEByteSource` to a custom FFmpeg `AVIOContext`, parses tracks, and builds a packet index.
- `FMETrackReader` exposes Core Media track information and independent sample cursors.
- `FMESampleCursor` supports decode/presentation stepping, seeking, dependency flags, and compressed `CMSampleBuffer` delivery.
- `FMEVideoDecoder` decodes VP9 to BGRA for SDR or 10-bit `x420`/`xf20` for HDR.

## Licensing

Original FFmpeg Media Extension code is Copyright © 2026 Ēriks Remess and is
available under the [MIT License](LICENSE).

The application statically links libraries from FFmpeg 9.0. FFmpeg remains
under its upstream GNU LGPL v2.1-or-later license and is not covered by the MIT
license. This project deliberately disables FFmpeg's GPL, version-3, and
nonfree configuration options. See [Third-Party Notices](THIRD_PARTY_NOTICES.md)
for attribution, source availability, and relinking information.

Tagged releases include both the signed application archive and a corresponding
source archive containing the exact pinned FFmpeg source and all project source
and build scripts used to produce the application.
