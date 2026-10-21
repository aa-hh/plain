#!/usr/bin/env bash
# Renders the logo with scripts/make-logo.swift and packs it into Support/AppIcon.icns.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift "$root/scripts/make-logo.swift" "$work/logo.png" 1024 > /dev/null
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/logo.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$work/logo.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$root/Support/AppIcon.icns"
echo "Support/AppIcon.icns"
