#!/bin/zsh
set -euo pipefail

app="$1"
extension="$app/Contents/Extensions/MKVFormatReader.appex"
decoder="$app/Contents/Extensions/FFmpegVideoDecoder.appex"

test -x "$app/Contents/MacOS/FFmpeg Media Extension"
test -x "$extension/Contents/MacOS/MKVFormatReader"
test -x "$decoder/Contents/MacOS/FFmpegVideoDecoder"
plutil -lint "$app/Contents/Info.plist" "$extension/Contents/Info.plist" "$decoder/Contents/Info.plist"
codesign --verify --deep --strict "$app"
file "$extension/Contents/MacOS/MKVFormatReader" | grep -q 'arm64'
file "$decoder/Contents/MacOS/FFmpegVideoDecoder" | grep -q 'arm64'

echo "Bundle structure, signatures, and Apple silicon architectures are valid."
