# FFmpeg Media Extension

Play Matroska and WebM files in QuickTime Player and other compatible Mac apps.

**Requires an Apple-silicon Mac running macOS 15 or newer.**

## Download and install

1. Download **ffmpeg-media-extension-macos-arm64.zip** from the
   [latest release](https://github.com/EriksRemess/ffmpeg-media-extension/releases/latest).
2. Unzip it and move **FFmpeg Media Extension.app** to **Applications**.
3. Open the app once.
4. In **System Settings → General → Login Items & Extensions**, find
   **FFmpeg Media Extension** under **By App**, click its info button, and
   enable **Media Extensions**.
5. Quit and reopen QuickTime Player.

You can now open a video using **QuickTime Player → File → Open File**, or
right-click it in Finder and choose **Open With → QuickTime Player**.
The extension app does not need to stay open.

## Compatibility

Supports `.mkv`, `.webm`, `.mka`, `.mks`, and `.mk3d` files, including many
common video and audio formats and HDR video. Playback support depends on the
contents of the file and the app opening it.

Embedded SRT subtitle support is experimental. Opening a movie with subtitles
can take longer. QuickTime may initially show subtitles while its menu says
**Off**. To hide them, select **On**, then **Off**; switching them on and off
works afterward.

If a file will not open, check that Media Extensions are enabled, then quit
and reopen the player. Do the same after replacing the app with a newer version.

## About

An independent, unofficial project by Ēriks Remess, not affiliated with or
endorsed by FFmpeg. Project code is available under the [MIT License](LICENSE);
see [Third-Party Notices](THIRD_PARTY_NOTICES.md) for FFmpeg licensing.

For building, testing, or contributing, see the [development guide](development.md).
