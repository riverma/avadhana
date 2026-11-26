# Changelog

All notable changes to Avadhāna are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/).

## [1.0.2] - 2026-11-25

### Added

- A "Browsers open to" setting under General (DuckDuckGo by default), used when a browser you've added opens without an address bar. An empty or invalid address falls back to DuckDuckGo.
- "Hide the menu bar" setting under General, on by default; the menu bar is restored when the session ends.
- A "Hide address bar and tabs for browsers I've added" setting under General, on by default.

### Fixed

- Apps in full screen or on another desktop come forward and fill the screen when opened from Avadhāna (#1).
- Browsers added to the apps list are no longer closed or hidden by Avadhāna (#1).
- Back works in a browser added as an app when Safari is the chosen site browser.
- Leaving the Shortcuts tab while recording a shortcut no longer leaves all shortcuts switched off.

## [1.0.1] - 2026-11-25

### Fixed

- Sites accept local addresses such as `localhost:3000`, `127.0.0.1` and `192.168.x.x`, opened over http (#2).
- Browsers can be added to the apps list like any other app.

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

[1.0.2]: https://github.com/riverma/avadhana/releases/tag/v1.0.2
[1.0.1]: https://github.com/riverma/avadhana/releases/tag/v1.0.1
[1.0.0]: https://github.com/riverma/avadhana/releases/tag/v1.0.0
