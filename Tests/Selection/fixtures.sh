#!/bin/bash
set -euo pipefail

# Run from the repository root with a full FFmpeg CLI and Python 3 installed.
# The project's minimal static FFmpeg build does not include the CLI/encoders.
fixture_dir=build/subtitle-selection-fixtures
mkdir -p "$fixture_dir"
cat > "$fixture_dir/captions.srt" <<'CAPTIONS'
1
00:00:01,000 --> 00:00:08,000
Subtitle selection test

2
00:00:10,000 --> 00:00:18,000
Second caption
CAPTIONS
ffmpeg -v error -f lavfi -i color=c=navy:s=640x360:r=24:d=20 \
    -i "$fixture_dir/captions.srt" -map 0:v -map 1:s \
    -c:v libx264 -preset ultrafast -c:s mov_text \
    -metadata:s:s:0 language=eng -y "$fixture_dir/grouped.mov"
ffmpeg -v error -i "$fixture_dir/grouped.mov" -map 0 -c:v copy -c:s srt \
    -metadata:s:v:0 language=eng -metadata:s:s:0 language=eng \
    -y "$fixture_dir/subtitles.mkv"

# Clear only the alternate-group field in the generated native MOV. Preserve
# sample payloads, timestamps, track flags, and all atom sizes/offsets.
python3 - "$fixture_dir" <<'PY'
import struct
import sys
from pathlib import Path
root = Path(sys.argv[1])
data = bytearray((root / 'grouped.mov').read_bytes())
def atoms(start, end):
    while start + 8 <= end:
        size, kind = struct.unpack_from('>I4s', data, start)
        if size < 8 or start + size > end:
            raise ValueError('Unexpected atom in generated fixture')
        yield start, size, kind
        start += size
changed = 0
for pos, size, kind in atoms(0, len(data)):
    if kind != b'moov':
        continue
    for tpos, tsize, tkind in atoms(pos + 8, pos + size):
        if tkind != b'trak':
            continue
        for hpos, hsize, hkind in atoms(tpos + 8, tpos + tsize):
            if hkind != b'tkhd':
                continue
            base = hpos + 8
            if hsize < 48 or data[base] != 0:
                raise ValueError('Expected version-0 track header')
            group = struct.unpack_from('>H', data, base + 34)[0]
            if group:
                struct.pack_into('>H', data, base + 34, 0)
                changed += 1
if changed != 1:
    raise ValueError(f'Expected one subtitle alternate group, found {changed}')
(root / 'ungrouped.mov').write_bytes(data)
PY
printf 'Created subtitle selection fixtures in %s\n' "$fixture_dir"
