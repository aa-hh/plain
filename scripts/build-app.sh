#!/usr/bin/env bash
# Builds Plain in release mode and assembles build/Plain.app.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# The release compile runs here (the .app needs its products), under a capacity
# permit from the pool every session shares; see scripts/lib/runner.sh.
. "$root/scripts/lib/runner.sh"
capacity_acquire build-app
swift build -c release
bin="$(swift build -c release --show-bin-path)"

app="$root/build/Plain.app"
contents="$app/Contents"
resources="$contents/Resources"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$resources/fonts"

cp "$bin/Plain" "$contents/MacOS/Plain"
cp "$root/Support/Info.plist" "$contents/Info.plist"
printf 'APPL????' > "$contents/PkgInfo"

for bundle in "$bin"/*.bundle; do
  cp -R "$bundle" "$resources/"
done

cp "$root/Sources/PlainVendor/Resources/fonts/"*.ttf "$resources/fonts/"

if [[ -f "$root/Sources/Plain/Resources/bin/plain" ]]; then
  mkdir -p "$resources/bin"
  cp "$root/Sources/Plain/Resources/bin/plain" "$resources/bin/plain"
  chmod +x "$resources/bin/plain"
fi

if [[ -f "$root/Support/AppIcon.icns" ]]; then
  cp "$root/Support/AppIcon.icns" "$resources/AppIcon.icns"
fi

licences="$root/Sources/Plain/Resources/Licences.md"
if [[ -f "$licences" ]]; then
  {
    cat "$licences"
    for file in "$root"/Sources/PlainVendor/Resources/*/LICENSE "$root"/Sources/PlainVendor/Resources/*/OFL.txt; do
      [[ -f "$file" ]] || continue
      printf '\n\n## %s\n\n```\n' "$(basename "$(dirname "$file")")/$(basename "$file")"
      cat "$file"
      printf '\n```\n'
    done
  } > "$resources/Licences.md"
fi

capacity_release
codesign --force --sign - --deep "$app"

echo "build/Plain.app"
