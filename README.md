# wpe-setup

Wallpaper Engine wallpapers on Linux, set up by a single command — with a real
backup and a real rollback.

## 1. Purpose

`linux-wallpaperengine` renders Wallpaper Engine Workshop wallpapers on Linux,
but getting it to actually draw takes a chain of undocumented steps. The most
punishing one is silent:

> **If no PulseAudio-compatible server answers on the session socket, the engine
> deadlocks in `PulseAudioPlayingDetector`'s constructor.** It still creates its
> layer surface at the right geometry, so the wallpaper layer exists — at alpha
> 0, forever, with no error message and no wallpaper file ever opened.

The fix is one flag, `--noautomute`. Finding it took a gdb backtrace of a hung
process. This tool applies it, discovers every path instead of assuming it, and
never touches anything it has not backed up first.

It also, deliberately, refuses to pretend: it tells you up front when your
compositor cannot host a wallpaper layer at all.

## 2. Prerequisites

Hard requirements, all verified by `check` before anything is written:

| Requirement | Why |
|---|---|
| Wallpaper Engine owned and installed via Steam | Its `assets/` folder holds the shaders and materials `scene` wallpapers need |
| At least one Workshop wallpaper subscribed | Nothing to render otherwise |
| `linux-wallpaperengine` on `PATH` | The renderer itself |
| `jq`, `find`, `awk` | Parsing and discovery |
| A compositor implementing `wlr-layer-shell` | See below |

**Compositor support is not universal, and cannot be made so.** The engine draws
through `wlr-layer-shell`:

| Environment | Status |
|---|---|
| Hyprland, Sway, river, Wayfire, niri | Supported |
| KDE Plasma (Wayland) | Supported |
| X11 (any WM) | Supported via window/root mode |
| **GNOME (Wayland)** | **Not possible** — Mutter does not implement the protocol |

`matugen` is optional; when present, the colour scheme can be derived from a
real rendered frame of the animated wallpaper.

## 3. Install

```sh
git clone https://github.com/<you>/wpe-setup && cd wpe-setup
./wpe-setup.sh check      # audits prerequisites, writes nothing
./wpe-setup.sh install    # backs up first, then configures
```

Run `./wpe-setup.sh` with no arguments for an interactive menu.

To undo everything, at any time:

```sh
./wpe-setup.sh rollback
```

Rollback restores the archive taken before installation *and deletes files that
did not exist beforehand* — a restore that only unpacks an archive would leave
new files behind and is not a rollback.

### Daily use

```sh
wpe list            # id, type and title of every wallpaper
wpe set <id>        # apply one
wpe random          # apply a random one
wpe watch           # keep the engine alive; put this in your autostart
wpe stop            # stop rendering
```

`wpe watch` covers the two ways a wallpaper silently disappears: the engine
dying with nothing to restart it, and the monitor layout changing while the
engine keeps rendering to a stale set of outputs.

### Desktop integrations

`install` detects supported desktop setups and offers to wire the wallpapers
directly into them. Integrations live in `plugins/` and are entirely optional.

**`imperative-dots`** — exposes every Wallpaper Engine wallpaper inside the
Quickshell wallpaper picker, so `Super+W` lists them and selecting one hands it
to the engine instead of pushing a still frame to `awww`. It also parallelises
the picker's thumbnail generation, which upstream does one file at a time while
decoding every frame of animated GIFs.

Both patches are idempotent, anchored on text verified to exist first, and
skipped with a warning if upstream has changed the file — never applied blind.

Writing a plugin means one executable in `plugins/` answering four subcommands:

| Subcommand | Contract |
|---|---|
| `detect` | exit 0 if this setup is present |
| `targets` | list every file it will modify, one per line |
| `install` | apply the integration, idempotently |
| `status` | report what is currently applied |

`targets` is what makes rollback complete: `wpe-setup` archives those files
before the plugin runs, so undoing an integration restores the dotfiles it
edited.

## 4. Threat model

What this tool can do to a machine, and what constrains it.

| Surface | Exposure | Mitigation |
|---|---|---|
| Arbitrary file writes | Writes to `~/.config/wpe`, `~/.local/bin/wpe`, `~/.local/state/wpe*` only | Every target is listed in `backup_targets()`; nothing outside it is touched |
| Destroying an existing config | Real: users run installers on live setups | No write happens before a backup archive exists; a failed backup aborts the install |
| Privilege escalation | None — no `sudo`, no system paths, no services installed | Runs entirely as the invoking user |
| Remote code execution | None — no network access at any point | Nothing is downloaded, no `curl \| sh` |
| Path injection via Steam library files | `libraryfolders.vdf` is parsed for paths | Extracted paths are only ever used after `-d` existence checks; never evaluated |
| Untrusted Workshop content | Wallpapers are third-party and executed by the engine | Out of scope: the trust boundary is `linux-wallpaperengine` itself, not this tool |
| Killing unrelated processes | `pkill -x linux-wallpaper` matches the truncated `comm` name | Never `pkill -f`, which would match this script's own command line |

**Known residual risk.** The engine renders untrusted Workshop content
(shaders, scenes, and CEF-hosted web wallpapers) with your user's privileges.
That risk belongs to `linux-wallpaperengine` and Wallpaper Engine, and this tool
neither adds to nor reduces it. Do not subscribe to wallpapers you would not run
as a program.

## Licence

MIT.
