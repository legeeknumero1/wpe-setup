<div align="center">

# wpe-setup

**Wallpaper Engine wallpapers on Linux — one command, with a rollback that actually works.**

[![CI](https://github.com/legeeknumero1/wpe-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/legeeknumero1/wpe-setup/actions/workflows/ci.yml)
[![ShellCheck](https://img.shields.io/badge/shellcheck-strict-brightgreen)](https://www.shellcheck.net/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Shell](https://img.shields.io/badge/pure-bash-lightgrey)](https://www.gnu.org/software/bash/)

</div>

---

## The bug that eats an afternoon

You install [`linux-wallpaperengine`](https://github.com/Almamu/linux-wallpaperengine). You run it. Nothing happens.

No error. No crash. The process sits there at 1% CPU. `hyprctl layers` even shows the wallpaper surface, at exactly the right size — just permanently invisible. So you go hunting through GLEW errors, EGL contexts, compositor settings and scaling flags, and none of it is the problem.

Here is the problem, from a gdb backtrace of the hung process:

```
#2  ppoll ()
#3  pa_mainloop_poll ()                                    ← libpulse
#4  pa_mainloop_iterate ()
#5  PulseAudioPlayingDetector::PulseAudioPlayingDetector()
#6  WallpaperApplication::setupAudio()
#7  WallpaperApplication::show()
```

The engine deadlocks in the **auto-mute detector** — the feature that lowers wallpaper audio when another app plays sound. If your session's PulseAudio socket exists but nothing is listening on it (a dead, failed, or not-yet-started audio service), `libpulse` connects and waits forever. Startup never reaches the point of opening the wallpaper file.

The fix is a single flag: **`--noautomute`**.

`wpe-setup` passes it, and takes care of everything else that has to be right.

## Quick start

```sh
git clone https://github.com/legeeknumero1/wpe-setup
cd wpe-setup
./wpe-setup.sh
```

That's it — you get a menu. Prefer it non-interactive?

```sh
./wpe-setup.sh check      # audit prerequisites, write nothing
./wpe-setup.sh install    # back up first, then configure
./wpe-setup.sh rollback   # put everything back
```

## What `check` looks like

```
Prerequisites
  ✓ Compositor: hyprland (wlr-layer-shell available)
  ✓ Engine: /usr/bin/linux-wallpaperengine
  ✓ Steam: 1 library(ies)
  · ~/.local/share/Steam
  ✓ Wallpaper Engine assets: ~/.local/share/Steam/steamapps/common/wallpaper_engine/assets
  ✓ Workshop wallpapers: 226
  ✓ Audio: PipeWire — --noautomute will be applied (mandatory)
  ✓ Dependencies: jq, find, awk
  ✓ matugen present — colour sync available
  ✓ Integration available: imperative-dots

Verdict
  ✓ Everything is ready
```

`check` never writes anything. `install` refuses to start until it has produced a restorable archive.

## Daily use

```sh
wpe list            # id, type and title of every wallpaper
wpe set <id>        # apply one
wpe random          # apply a random one
wpe watch           # keep the engine alive — put this in your autostart
wpe stop            # stop rendering
```

`wpe watch` covers the two ways a wallpaper silently vanishes: the engine dying with nothing to restart it, and the monitor layout changing while the engine keeps drawing to outputs that no longer exist.

## Nothing is hardcoded

Steam moves around. People use Flatpak, Snap, a second SSD, a custom library folder. So every path is discovered at runtime — native, Flatpak and Snap roots, plus every extra library declared in `libraryfolders.vdf`. Same for outputs (`hyprctl`, `swaymsg`, `wlr-randr`, `xrandr`), the engine binary, and the audio server.

CI enforces it: a build fails if a `/home/<user>/` path ever appears in the source.

## Compatibility

| Environment | Status |
|---|---|
| Hyprland, Sway, river, Wayfire, niri | Supported |
| X11 (any WM) | Supported via window/root mode |
| KDE Plasma (Wayland) | Manual setup only — see below |
| GNOME (Wayland) | Not possible |

**GNOME** — Mutter [does not implement `wlr-layer-shell`](https://gitlab.gnome.org/GNOME/mutter/-/issues/973), and no installer can work around that.

**Plasma** — KWin *does* implement the protocol, but Plasma's desktop containment draws above the background layer, so a wallpaper placed there is simply hidden. The working recipe is window mode plus KWin window rules ([upstream discussion #472](https://github.com/Almamu/linux-wallpaperengine/discussions/472)), which cannot be automated and costs the desktop icons. `check` tells you this instead of pretending.

## Requirements

| Requirement | Why |
|---|---|
| Wallpaper Engine owned and installed via Steam | Its `assets/` folder holds the shaders `scene` wallpapers need |
| At least one Workshop wallpaper subscribed | Nothing to render otherwise |
| `linux-wallpaperengine` on `PATH` | The renderer |
| `jq`, `find`, `awk` | Discovery and parsing |

`matugen` is optional. When present, the colour scheme can be derived from a real rendered frame of the animated wallpaper — so a moving background still drives your theme.

## Rollback, properly

Most installers back up by copying a folder and hoping. This one:

- **verifies the archive lists** before touching anything
- **rehearses the extraction** into a staging directory, so a corrupt backup fails *before* any file is deleted
- **removes files it created**, not just restoring ones it edited — a restore alone would leave new files behind
- **keeps the pristine snapshot** across re-installs, because a second backup captures the already-installed system

Run `install` twice then `rollback`, and you land on the state you started from.

## Desktop integrations

`install` detects supported desktop setups and offers to wire the wallpapers directly into them. Integrations live in `plugins/` and are entirely optional.

**`imperative-dots`** — exposes every wallpaper inside the Quickshell picker, so `Super+W` lists them and selecting one hands it to the engine instead of pushing a frozen frame to `awww`. It also parallelises the picker's thumbnail generation, which upstream runs one file at a time while decoding every frame of animated GIFs.

Writing a plugin means one executable answering five subcommands:

| Subcommand | Contract |
|---|---|
| `detect` | exit 0 if this setup is present |
| `targets` | list every **pre-existing** file it will modify |
| `install` | apply the integration, idempotently |
| `cleanup` | remove the files it created, by name |
| `status` | report what is currently applied |

Patches are idempotent and anchored on text verified to exist first. If upstream changed the file, the patch is **skipped with a warning** rather than applied blind.

## FAQ

**Do I need to own Wallpaper Engine?**
Yes. It is a paid Steam app, and its `assets/` folder is what `scene` wallpapers are built against. There is no substitute.

**Does this modify Wallpaper Engine or my Steam files?**
No. Workshop content is read-only to this tool.

**Does it need root?**
No. Everything lives under `~/.config`, `~/.local/bin` and `~/.local/state`.

**My wallpaper has white bars on the sides.**
Check the source video first — plenty of Workshop uploads have the bars baked into the file, in which case no scaling mode can help.

**Why Bash and not a compiled binary?**
Because "copy, paste, done" beats "install a toolchain first" for a setup tool. The whole thing is auditable in one sitting, and CI lints it at ShellCheck's strictest level.

## Threat model

| Surface | Exposure | Mitigation |
|---|---|---|
| Arbitrary file writes | `~/.config/wpe`, `~/.local/bin/wpe`, `~/.local/state/wpe*` only | Every target is declared; nothing outside it is touched |
| Destroying an existing config | Real — installers get run on live setups | No write before a verified archive exists; a failed backup aborts the install |
| Privilege escalation | None — no `sudo`, no system paths, no services | Runs entirely as the invoking user |
| Remote code execution | None — no network access at any point | Nothing is downloaded, no `curl \| sh` |
| Path injection via Steam files | `libraryfolders.vdf` is parsed for paths | Extracted paths are existence-checked, never evaluated |
| Killing unrelated processes | `pkill -x linux-wallpaper` matches the truncated `comm` | Never `pkill -f`, which would match this script's own command line |

**Residual risk.** The engine renders untrusted Workshop content — shaders, scenes, and CEF-hosted web wallpapers — with your user's privileges. That risk belongs to `linux-wallpaperengine` and Wallpaper Engine; this tool neither adds to nor reduces it. Don't subscribe to wallpapers you wouldn't run as a program.

## Contributing

Tested daily on Hyprland. The other compositors are implemented from their documented interfaces but not yet exercised on real hardware — **reports from Sway, river, Wayfire, niri and X11 are especially welcome**, working or not.

CI must stay green: ShellCheck at `-S style`, syntax parse, plugin contract, and no hardcoded paths.

## Licence

MIT.
