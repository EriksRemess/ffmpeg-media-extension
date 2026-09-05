#!/bin/bash
set -euo pipefail

probe="$1"
local_media_dir="${FME_LOCAL_MEDIA_DIR:-$HOME/Movies}"
share_media_dir="${FME_SHARE_MEDIA_DIR:-}"

shopt -s nullglob
local_candidates=("$local_media_dir"/*.mkv "$local_media_dir"/*.webm)

tested=0
for media in "${local_candidates[@]}"; do
    if [[ -f "$media" ]]; then
        FME_PROBE_SAMPLES=20 "$probe" "$media"
        FME_PROBE_START=60 FME_PROBE_SAMPLES=20 "$probe" "$media"
        # Cross the 4096-packet compaction boundary, and request an explicit
        # range through EOF for shorter clips. Short implicit-range probes
        # alone do not exercise QuickTime's last-sample discovery path.
        FME_PROBE_SECONDS=240 FME_PROBE_SAMPLES=20000 "$probe" "$media"
        # A narrow pass-through reader range after the final sync sample can
        # legitimately be empty. Image generation still exercises the tail
        # cursor and dependency walk without assuming a particular GOP size.
        FME_PROBE_END_OFFSET=1.0 FME_PROBE_MEDIA_TYPE=image "$probe" "$media"
        (( tested += 1 ))
    fi
done

if [[ -n "$share_media_dir" ]]; then
    for media in "$share_media_dir"/*.mkv "$share_media_dir"/*.webm; do
        if [[ -f "$media" ]]; then
            FME_PROBE_START=60 FME_PROBE_SAMPLES=20 "$probe" "$media"
            FME_PROBE_END_OFFSET=1.0 FME_PROBE_MEDIA_TYPE=image "$probe" "$media"
            (( tested += 1 ))
        fi
    done
fi

if (( tested == 0 )); then
    printf '%s\n' "No MKV/WebM integration-test media was found." >&2
    exit 66
fi

printf 'Functional open, sequential-read, decode, and seek probes passed for %d media files.\n' "$tested"
