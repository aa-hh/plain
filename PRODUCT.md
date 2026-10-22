# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS 27 app: SwiftUI, with AppKit for the text view, windows and menus. Not one of the schema's four values; recorded as-is.

## Users

People who write in Markdown on a Mac and want the editor to stay out of the way: notes, docs, drafts, folders of `.md` files. Plain is a public product, not a personal tool.

## Product Purpose

A Markdown editor that styles Markdown as you type, shows a live preview, works on a whole folder of files, and exports to PDF and HTML. Success means it opens instantly, never drops a keystroke and never loses text.

## Positioning

Fast and quiet first. Plain started as a native rebuild of Caret's behaviour (`docs/caret-behaviour-spec.md`), but Caret is the starting point, not the identity. Speed targets are written into release tests (`docs/DESIGN.md`, Speed): for example 8 ms per keystroke at the 95th percentile and 50 ms to switch to a 1 MB tab.

## Operating Context

- Single files and whole folders, with a Files sidebar, an outline, find in folder and Git change marks.
- Tabs, and a live preview beside the editor.
- A `plain` command opens files from the terminal.
- Settings live in two Markdown files opened as tabs; user data lives in `~/Library/Application Support/Plain/`.

## Capabilities and Constraints

- Shipped feature set and every deviation from the Caret spec: `docs/DESIGN.md`.
- Distribution: Mac App Store. The current build is not yet ready for its sandbox rules. Known conflicts: Git marks run `/usr/bin/git`, the `plain` command is a symlink the user creates in `/usr/local/bin`, and folder access and file watching need user-granted folder permissions that persist across launches.
- Pricing: undecided.
- Never copy Caret's code, CSS, themes, icons, font data or welcome text, or use its name or branding.

## Brand Commitments

- Name: Plain.
- An app icon exists (`scripts/make-logo.swift`, `scripts/make-icon.sh`); it is a starting point, not confirmed branding.

## Evidence on Hand

- Release speed numbers: `docs/DESIGN.md`, Speed.
- Welcome folder content: `Sources/Plain/Resources/Welcome/`.
- No users, testimonials, reviews, press or pricing yet. Do not invent any.

## Product Principles

1. Speed is a feature. A change that slows typing, opening or tab switching past the release test limits does not ship.
2. Never lose text. Saving, quitting and renaming keep every unsaved edit.
3. Stay out of the way. Chrome, prompts and notifications earn their place or go.
4. Behave like a Mac app: native menus, shortcuts, windows and text handling.
