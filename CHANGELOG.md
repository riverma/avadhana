# Changelog

All notable changes to Avadhāna are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-17

First public release.

### Added

- Full-screen home screen of chosen apps and websites, in grid or rows, with type-to-search and keyboard navigation.
- Allowlist while Avadhāna is on: other apps are closed when opened; apps already open are hidden and restored on exit.
- Apps and sites fill the main display above a bottom bar with Home, Back, Settings and Exit.
- Websites without an address bar or tabs in Safari (WebKit), Firefox or Google Chrome, each in a separate profile. Allowed domains are enforced in Safari mode.
- Configurable Home (⌘Esc) and Back (⌃⌘⌫) shortcuts that work in every app, with optional "Ignore while typing".
- Settings for apps, sites, web browser, layout and shortcuts; tiles arranged by dragging or from a tile's menu.
- Web links from your apps and links clicked in your sites open one page at a time in the chosen browser, staying on that page's site. Links from apps are moved out of your usual browser as it opens them (with Accessibility access); the default browser is never changed.
- Apps on your list can be opened from Spotlight during a session; others are closed with a message.
- Update checks against GitHub releases, shown only in Settings, with one-click install of signature-verified updates.
- `--start` launch argument, and `kill` ends a session cleanly.
- Dock hidden while Avadhāna is on, with crash-safe restore.
- Universal (Apple silicon and Intel) build, DMG packaging and notarization scripts.
- Project website in `docs/`.
- Unit tests (`swift test`) for site addresses, allowed domains, link rules, settings, tile order, shortcuts and updates, run by GitHub Actions.

[1.0.0]: https://github.com/riverma/avadhana/releases/tag/v1.0.0
