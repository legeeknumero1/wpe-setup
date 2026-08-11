# Changelog

Notable changes, newest first. Follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `0.x` series is early development: the interface may still change between
minor versions, and `rollback` is the safety net that makes that acceptable.

## [0.1.0] — 2026-08-11

First public release.

### Added

- `check`, `install`, `rollback` and `status`, plus an interactive menu.
- The `wpe` runtime: `list`, `set`, `random`, `watch`, `stop`, `colors`.
- **Escalating Steam discovery.** Conventional locations, then paths Steam
  records about itself, then the launcher resolved through `PATH` and Flatpak,
  then a depth-limited filesystem scan under a timeout. Around 100 ms when Steam
  is where you would expect, ~150 ms for a library on a second drive, and no
  hang at all on a machine with no Steam.
- **Verified backup and rollback.** Nothing is written before a restorable
  archive exists. Rollback lists the archive, rehearses the extraction into a
  staging directory, and only then removes anything — and it removes files it
  created as well as restoring ones it edited.
- **`wpe watch`**, keeping the engine alive and rebinding it when the monitor
  layout changes.
- **Optional palette sync**, derived from a real rendered frame so animated
  wallpapers still drive the colour scheme.
- **Plugin system** with a six-subcommand contract, and an `imperative-dots`
  integration exposing every wallpaper inside the Quickshell picker.
- **28-case test suite** running against synthetic Steam trees in throwaway
  home directories, wired into CI alongside ShellCheck at `-S style`, a syntax
  gate, a plugin-contract check and a hardcoded-path guard.
- `PKGBUILD` for Arch-based distributions.

### Notes

The behaviour this project exists for: `linux-wallpaperengine` deadlocks in
`PulseAudioPlayingDetector`'s constructor when the session's PulseAudio socket
has no listener, creating its layer surface but never rendering and never even
opening the wallpaper file. `--noautomute` avoids it, and is passed
unconditionally. Reported upstream as
[Almamu/linux-wallpaperengine#649](https://github.com/Almamu/linux-wallpaperengine/issues/649).

GNOME Wayland cannot be supported — Mutter does not implement
`wlr-layer-shell`. KDE Plasma needs manual setup, because its desktop
containment draws above the background layer. Both are reported by `check`
rather than left for users to discover.

[0.1.0]: https://github.com/legeeknumero1/wpe-setup/releases/tag/v0.1.0
