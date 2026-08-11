<div align="center">

# wpe-setup

**Wallpaper Engine wallpapers on Linux — one command, with a rollback that actually works.**

[![CI](https://github.com/legeeknumero1/wpe-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/legeeknumero1/wpe-setup/actions/workflows/ci.yml)
[![ShellCheck](https://img.shields.io/badge/shellcheck-strict-brightgreen)](https://www.shellcheck.net/)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Shell](https://img.shields.io/badge/pure-bash-lightgrey)](https://www.gnu.org/software/bash/)

</div>

https://github.com/user-attachments/assets/0c7782ad-6f9f-47c5-bdf8-e05276fff6b9

<div align="center">

<sub>Two changes, straight from the desktop's own picker. Each background is a live animated wallpaper, and the palette is re-derived from a real rendered frame — watch the bar and the terminal follow it from gold, to neon blue, to orange.<br>
Video not playing? Same clip as an <a href="docs/demo.gif">animated GIF</a>.</sub>

</div>

> [!WARNING]
> **Early development.** This works well enough to be used daily, but it is new
> and lightly tested: expect rough edges, and read [Known issues](#known-issues)
> before installing. `rollback` exists precisely because you may want it — it is
> tested, and it restores files byte-for-byte.

---

## What this is

[`linux-wallpaperengine`](https://github.com/Almamu/linux-wallpaperengine) is the project that does the hard part: it renders Wallpaper Engine's Workshop content natively on Linux. It is excellent, and this tool would not exist without it.

What it does not do — by design, it is a renderer — is find your Steam library, work out your outputs, survive a monitor being unplugged, or put your config back when you change your mind. `wpe-setup` is the setup layer around it.

It also encodes one environment gotcha that is genuinely hard to diagnose alone.

### The silent hang

On a machine whose audio service is down, the engine starts and then simply stops: no error, ~1% CPU, and a wallpaper surface that exists at the right size but never displays. A gdb backtrace of the hung process shows where it waits:

```
#2  ppoll ()
#3  pa_mainloop_poll ()                                    ← libpulse
#4  pa_mainloop_iterate ()
#5  PulseAudioPlayingDetector::PulseAudioPlayingDetector()
#6  WallpaperApplication::setupAudio()
#7  WallpaperApplication::show()
```

It is stuck in the optional **auto-mute detector**. When the session's PulseAudio socket exists but nothing is listening on it — a dead, failed or not-yet-started audio service — `libpulse` connects and waits indefinitely, so startup never reaches the wallpaper.

`--noautomute` skips that detector entirely. It is the flag the community already uses on KDE, and `wpe-setup` passes it everywhere, because it costs nothing when audio is healthy.

If you only take one thing from this repository, take that flag.

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

### Arch, CachyOS, EndeavourOS

A `PKGBUILD` ships in the repository, so you can build a real pacman-managed
package without waiting on the AUR:

```sh
git clone https://github.com/legeeknumero1/wpe-setup
cd wpe-setup/packaging/aur && makepkg -si
```

That installs `wpe` and `wpe-setup` system-wide, resolves dependencies through
pacman, and uninstalls cleanly with `pacman -R wpe-setup-git`. Its `check()`
runs the same ShellCheck gate as CI, so a broken tree fails the build instead
of reaching your system.

> **Why not the AUR yet?** Arch [suspended new AUR registrations and paused all
> pushes](https://linuxiac.com/arch-linux-blocks-new-aur-registrations-amid-malware-cleanup/)
> during the 2026 malicious-package cleanup. The package will be submitted once
> that lifts; `makepkg -si` above gives you the identical result meanwhile.

## What `check` looks like

Sample run on one machine — the numbers are simply what was found there, not
thresholds of any kind:

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

## Paths are discovered, not assumed

Steam moves around. People use Flatpak, Snap, a second SSD, a relocated
`XDG_DATA_HOME`, a custom library folder. So nothing about your layout is
assumed:

- **Steam roots** — native, Flatpak and Snap locations are probed, `XDG_DATA_HOME` is honoured, `~/.steam/root` symlinks are followed, and every additional library declared in `libraryfolders.vdf` is picked up
- **Outputs** — `hyprctl`, `swaymsg`, `wlr-randr` or `xrandr`, whichever fits your session
- **Engine, audio server, `matugen`** — resolved through `PATH` and process state

Steam discovery escalates in tiers and stops at the first hit, so the ordinary
case stays instant while an unusual install is still found:

| Tier | Looks at |
|---|---|
| 1 | Conventional locations — native, Flatpak, Snap, `XDG_DATA_HOME`, `~/.steam` symlinks |
| 2 | What Steam records about itself — `registry.vdf`, `.steampath` |
| 3 | The launcher's own location, resolved through `PATH` and Flatpak |
| 4 | A depth-limited scan of `$HOME`, `/mnt`, `/media`, `/run/media`, `/srv`, `/opt`, under a 20-second timeout |

Then every extra library declared in `libraryfolders.vdf` is added, which is
what finds a games drive sharing nothing with the install directory.

Measured: ~100 ms when Steam is where you would expect, ~150 ms for a library
buried at `~/Games/MySSD/SteamLibrary`, and no hang at all on a machine with no
Steam anywhere. **"Not found" should mean it is genuinely not there.**

CI enforces the rest: the build fails if a `/home/<user>/` path ever appears in
the source.

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

Subscribed or unsubscribed something in Steam? Re-mirror the Workshop without
touching any patched file:

```sh
/usr/share/wpe-setup/plugins/imperative-dots.sh sync
```

It adds what is new and prunes what is gone. Pruning matters: an unsubscribed
wallpaper leaves its preview behind, and clicking that stale entry would apply
the still image as a static wallpaper instead of starting the engine.

| Subcommand | Contract |
|---|---|
| `detect` | exit 0 if this setup is present |
| `targets` | list every **pre-existing** file it will modify |
| `install` | apply the integration, idempotently |
| `sync` | re-mirror the Workshop: add new previews, prune removed ones |
| `cleanup` | remove the files it created, by name |
| `status` | report what is currently applied |

Patches are idempotent and anchored on text verified to exist first. If upstream changed the file, the patch is **skipped with a warning** rather than applied blind.

## Known issues

Stated plainly, because finding these yourself after installing is worse than
reading them here.

**Only Hyprland is genuinely tested.** Sway, river, Wayfire, niri and X11 are
implemented from their documented interfaces and exercised in sandboxes, but not
on real hardware. They may simply not work. Reports either way are welcome.

**Colour sync can be wrong on rare occasions.** The palette is derived from a
frame captured shortly after the wallpaper starts. A wallpaper that opens on a
black intro, a loading state, or a frame unrepresentative of the rest will
produce a palette that does not match what you end up looking at. Re-running
`wpe colors` after it has settled gives a better result.

**Scene wallpapers spike on load.** Expect a brief jump to 30–50% of one core
while a `scene` wallpaper initialises, settling to roughly 3–5%. Video
wallpapers are lighter throughout.

**Some wallpapers have their borders baked in.** If a wallpaper shows bars at
the edges, check the source file before blaming `--scaling`: plenty of Workshop
uploads are letterboxed in the video itself, and no scaling mode can undo that.

**Plugin patches are skipped when upstream changes.** Integrations anchor on
specific text in the files they edit. When a dotfiles project changes those
files, the patch is skipped with a warning rather than applied blind — safe, but
it means the integration silently does less than you expected. `status` tells
you what actually got applied.

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

## Credits and licensing

This project stands on other people's work, and the licence situation deserves
stating plainly rather than being buried.

**[`linux-wallpaperengine`](https://github.com/Almamu/linux-wallpaperengine) — GPL-3.0, by Almamu and contributors.**
It does the actual rendering. `wpe-setup` contains none of its code: it locates
the binary and runs it as a separate process. Under
[GPL-3.0's own aggregate clause](https://www.gnu.org/licenses/gpl-3.0.en.html),
invoking an independent program does not make the caller a derivative work, so
this repository is MIT. If you redistribute the engine itself, GPL-3.0 applies
to it — that obligation is yours, not this tool's.

**[`imperative-dots`](https://github.com/ilyamiro/imperative-dots) — no licence declared, by ilyamiro.**
The optional plugin edits *your local copy* of these dotfiles on your own
machine, which is yours to modify. It ships no code copied from that project:
the replacement it writes is independently written, and the short strings it
matches on exist only so a patch can be aborted when the file does not look as
expected. With no licence declared, the default is all rights reserved — so if
you fork or redistribute anything from that project, ask the author first.

**Wallpaper Engine** is a commercial Steam application by Kristjan Skutta. This
tool neither bundles nor circumvents it; you need to own it.

Everything in this repository is **MIT** — see [LICENSE](LICENSE).

If you maintain any of the projects above and want a citation changed, a claim
corrected, or this integration removed, open an issue and it will be handled.
