#!/usr/bin/env bash
# Downloads KaTeX, Prism, gemoji's emoji list and Roboto Mono into Sources/PlainVendor/Resources.
# Re-runnable: deletes and recreates the vendor folders each time.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/Sources/PlainVendor/Resources"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

katex_version="0.19.0"
prism_version="1.30.0"
gemoji_tag="v4.1.0"
roboto_commit="895ec691990d041dd727c7b5afa3ce56525d98e6"

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

fetch "https://registry.npmjs.org/katex/-/katex-$katex_version.tgz" "$tmp/katex.tgz"
fetch "https://registry.npmjs.org/prismjs/-/prismjs-$prism_version.tgz" "$tmp/prism.tgz"
mkdir -p "$tmp/katex" "$tmp/prism"
tar -xzf "$tmp/katex.tgz" -C "$tmp/katex"
tar -xzf "$tmp/prism.tgz" -C "$tmp/prism"

rm -rf "$dest/katex" "$dest/prism" "$dest/emoji" "$dest/fonts"
mkdir -p "$dest/katex/fonts" "$dest/prism/components" "$dest/emoji" "$dest/fonts"

cp "$tmp/katex/package/dist/katex.min.js" "$tmp/katex/package/dist/katex.min.css" "$dest/katex/"
cp "$tmp/katex/package/dist/fonts/"* "$dest/katex/fonts/"
cp "$tmp/katex/package/LICENSE" "$dest/katex/LICENSE"

cp "$tmp/prism/package/components/"*.min.js "$dest/prism/components/"
cp "$tmp/prism/package/components.json" "$dest/prism/components.json"
cp "$tmp/prism/package/LICENSE" "$dest/prism/LICENSE"

fetch "https://raw.githubusercontent.com/github/gemoji/$gemoji_tag/db/emoji.json" "$dest/emoji/emoji.json"
fetch "https://raw.githubusercontent.com/github/gemoji/$gemoji_tag/LICENSE" "$dest/emoji/LICENSE"

roboto="https://raw.githubusercontent.com/googlefonts/RobotoMono/$roboto_commit"
fetch "$roboto/fonts/ttf/RobotoMono-Regular.ttf" "$dest/fonts/RobotoMono-Regular.ttf"
fetch "$roboto/fonts/ttf/RobotoMono-Bold.ttf" "$dest/fonts/RobotoMono-Bold.ttf"
fetch "$roboto/OFL.txt" "$dest/fonts/OFL.txt"

echo "Vendor files written to $dest"
