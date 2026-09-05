# Generated subtitle test media

These small synthetic clips contain plain backgrounds and original test text.
They are kept outside `build/` so `make clean` does not remove them.

## Initial-state tests

Each clip in `initial-state/` runs for two minutes. Its caption,
“CAPTIONS ARE VISIBLE”, runs from 00:01 through 01:58.

- `english-three-letter.mkv`: H.264 and SRT, language tag `eng`.
- `english-canonical.mkv`: the same samples with language tag `en`.
- `native.mp4`: the same video and captions as native MP4 timed text.
- `captions.srt`: the source text and timing.

In QuickTime, check the subtitle menu immediately after opening, seek/play
inside the caption interval, and compare visible text with the menu state.
Then check On → Off → On. The observed MKV bug is initial Off with visible
captions; toggling On, then Off hides them, and subsequent toggles work.

## Selection-group tests

The clips in `selection-groups/` run for 20 seconds, with two captions.

- `grouped.mov`: native MOV with one subtitle alternate group.
- `ungrouped.mov`: the same MOV with only the alternate-group field cleared.
- `subtitles.mkv`: the video/captions remuxed as H.264 and SRT.
- `captions.srt`: the source text and timing.

Use `Tests/Selection/main.swift` to compare standalone AVURLAsset selection
queries. Those results alone do not establish whether QuickTime's runtime
subtitle controls work. `Tests/Selection/fixtures.sh` regenerates this set
under `build/subtitle-selection-fixtures/` without changing these saved copies.

## Separate forced-track tests

The two-minute clips in `forced-selection/` contain separate English regular
and forced subtitle tracks. Their original text reads “REGULAR CAPTION” and
“FORCED CAPTION” from 00:01 through 01:58. `forced-first.mkv` places the forced
track before the regular track; `separate-forced.mkv` uses the opposite order.
The two SRT files are retained alongside the clips.

These fixtures test selection between actual tracks. They require a reader
that maps the container's forced disposition to the subtitle format flags;
build 57 does not do that. The build 66 experiment did map those flags, but
QuickTime On did not select the regular track, so that experiment was reverted.
