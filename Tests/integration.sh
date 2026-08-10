#!/bin/bash
set -euo pipefail

probe="$1"
local_media_dir="${FME_LOCAL_MEDIA_DIR:-$HOME/Movies}"
share_media_dir="${FME_SHARE_MEDIA_DIR:-}"

shopt -s nullglob
local_candidates=("$local_media_dir"/*.mkv "$local_media_dir"/*.webm)
share_candidates=()
if [[ -n "$share_media_dir" ]]; then
    share_candidates=("$share_media_dir"/*.mkv "$share_media_dir"/*.webm)
fi

tested=0
for media in "${local_candidates[@]}"; do
    if [[ -f "$media" ]]; then
        FME_PROBE_SAMPLES=20 "$probe" "$media"
        FME_PROBE_START=60 FME_PROBE_SAMPLES=20 "$probe" "$media"
        (( tested += 1 ))
    fi
done

for media in "${share_candidates[@]}"; do
    if [[ -f "$media" ]]; then
        FME_PROBE_START=60 FME_PROBE_SAMPLES=20 "$probe" "$media"
        (( tested += 1 ))
    fi
done

if (( tested == 0 )); then
    printf '%s\n' "No MKV/WebM integration-test media was found." >&2
    exit 66
fi

printf 'Functional open, sequential-read, decode, and seek probes passed for %d media files.\n' "$tested"
