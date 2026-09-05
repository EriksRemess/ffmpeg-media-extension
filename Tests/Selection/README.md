# Subtitle selection diagnostics

Run these commands from the repository root. The saved fixtures contain only
original test text and generated video; no private media is required.

```sh
mkdir -p build
xcrun swiftc Tests/Selection/group-only.swift \
    -framework AVFoundation -framework MediaToolbox -o build/group-only
build/group-only Tests/Fixtures/Subtitles/initial-state/english-canonical.mkv \
    Tests/Fixtures/Subtitles/initial-state/native.mp4

xcrun swiftc Tests/Selection/main.swift \
    -framework AVFoundation -framework MediaToolbox -o build/selection-probe
build/selection-probe Tests/Fixtures/Subtitles/initial-state/english-three-letter.mkv \
    Tests/Fixtures/Subtitles/initial-state/english-canonical.mkv \
    Tests/Fixtures/Subtitles/initial-state/native.mp4

xcrun clang -fobjc-arc -Wall -Wextra Tests/Selection/webvtt-format.m \
    -framework Foundation -framework CoreMedia -o build/webvtt-format
build/webvtt-format
```

`group-only.swift` requests only `loadMediaSelectionGroup(for: .legible)` on a
fresh AVURLAsset. It avoids other property queries that can obscure the original
error. `main.swift` additionally inspects track flags, language, and formats.
`webvtt-format.m` checks format creation, display-flag access, and serialization;
it does not install a reader or establish that WebVTT playback works.

## Observed on 2026-09-05

Environment: macOS 27.0 beta (26A5425a), reader build 57.

- The native MP4 opens with captions selected, and QuickTime shows On and
  Language → English. Its legible selection group is available.
- Both MKV language variants (`eng` and `en`) render captions while QuickTime
  initially reports Off. Direct legible-group loading fails with underlying
  OSStatus -16505. This happens without querying other properties first.
- After On → Off, captions disappear. Subsequent On/Off changes work. The
  initial-state bug must not be described as a completely nonfunctional toggle.
- QuickTime logs show automatic selection of the MKV subtitle track, followed
  by AVKit reporting its custom Off option. Its runtime options include a normal
  subtitle option and an associated forced-only option.

## Rejected experiments

All were reverted; the runtime source and installed app were restored to build 57.

| Experiment | Result |
| --- | --- |
| Subtitle enabled by default (60) | Caption visible, but AVKit still reports Off at startup. |
| `text/tx3g` instead of `sbtl/tx3g` (61) | QuickTime exposes no legible selection options; no usable subtitle playback. |
| `sbtl/wvtt`, ISO WebVTT cue boxes (62) | QuickTime rejects the asset with -12718 before rendering. |
| WebVTT with explicit DisplayFlags = 0 (63) | Selection-group loading still fails with -12718; the explicit extension does not make the text-display-flags getter work. |
| Optional sample-size/data-rate callbacks (64) | Direct group loading still fails with -16505; neither diagnostic callback is requested by that query. |
| Explicit `und` subtitle language (65) | Initially hides captions, but QuickTime On cannot enable them. Rejected after manual testing. |
| Separate forced and regular subtitle tracks (66) | Initially selects the forced track, but QuickTime On does not switch to the regular track. Rejected after manual testing. |
| Omit optional metadata callbacks (67) | Asset loading fails with -16155, including ordinary playback. Reverted immediately. |
| Nonempty file/track title metadata (68) | AVFoundation receives the titles and captions render, but group loading still fails with -16505. Diagnostic only; not retained. |
| QuickTime `mdta` title/display-name metadata (69) | AVFoundation receives the metadata in this key space too, but group loading still fails with -16505. Not retained. |

`player.m` is a standalone AVPlayer diagnostic that reports legible-output cues,
enabled item tracks, and current selection. Compile it with Foundation,
AVFoundation, MediaToolbox, and CoreMedia. Run each `auto`, `manual`, `forced`,
or `normal` case in a fresh process. These modes set player selection criteria;
they do not reproduce QuickTime's menu actions or change system caption settings.
In particular, a successful `normal` case is not proof that QuickTime On works.
The probe fails if playback does not advance to three seconds within its
eight-second deadline, even if the item reports ready.

A debugger trace of build 57 identified an empty-metadata-array conversion in
Apple's ExtensionShim as one source of -16505. Providing nonempty metadata
eliminated that observed wrapper error, but did not make selection-group loading
succeed. This distinction matters: the empty-array error alone does not explain
the subtitle selection failure, and changing metadata has not fixed it.

WebVTT format construction and serialization succeed in the standalone probe,
while `CMTextFormatDescriptionGetDisplayFlags` returns
`kCMFormatDescriptionError_ValueNotAvailable` (-12718). This is consistent with
an incompatible format-property request, but does not prove the internal cause
of QuickTime's failure or that WebVTT is unsupported in every AVFoundation path.

The evidence points toward a mismatch in the MediaExtension/AVFoundation
selection integration. The precise cause is not established, and no safe
extension-side fix has been verified. A comparison on a stable macOS release
and an Apple report using these fixtures would help distinguish an OS regression
from a format-reader limitation. Do not repeat the rejected changes solely on
the basis of standalone group-query results; verify visible captions and the
initial menu state in QuickTime as well.
