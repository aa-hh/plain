# Plain

A Markdown editor for macOS 27, written in SwiftUI with AppKit for the text view, windows and menus. It styles Markdown as you type, shows a live preview, and exports to PDF and HTML. `docs/DESIGN.md` explains how it is built.

## Build

Needs Xcode 27 (Swift 6.4).

```sh
bash scripts/fetch-vendor.sh   # only when Sources/PlainVendor/Resources/ is missing or out of date
swift build
bash scripts/build-app.sh      # release build, assembled and signed as build/Plain.app
```

`fetch-vendor.sh` downloads KaTeX, Prism, the gemoji emoji list and Roboto Mono into `Sources/PlainVendor/Resources/`. Never edit those files by hand.

## Test

```sh
swift test --filter PlainCoreTests                       # one suite; each module has <Module>Tests
swift test -c release --filter PerformanceTests          # speed tests, release only
```

## Run

```sh
open build/Plain.app
```

To install, copy `build/Plain.app` to `/Applications`. The `plain` command opens files from the terminal:

```sh
ln -s /Applications/Plain.app/Contents/Resources/bin/plain /usr/local/bin/plain
plain notes.md
```

Settings, window state, backups and the Welcome folder live in `~/Library/Application Support/Plain/`.

## Licences

Plain bundles swift-markdown, swift-cmark, Yams, KaTeX, Prism, gemoji and Roboto Mono. `Sources/Plain/Resources/Licences.md` lists them with their licences, and the app shows it under Help › Third-Party Licences with the full licence texts appended.
