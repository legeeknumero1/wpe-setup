# Security policy

## Scope

`wpe-setup` runs entirely as the invoking user. It never requests `sudo`, never
writes outside `~/.config`, `~/.local/bin` and `~/.local/state`, and makes no
network requests at any point — nothing is downloaded, and there is no
`curl | sh` installation path.

The full threat model, including what is deliberately out of scope, is in the
[README](README.md#threat-model).

## Reporting a vulnerability

Open a [security advisory](https://github.com/legeeknumero1/wpe-setup/security/advisories/new)
rather than a public issue. Expect a first response within a week.

Reports that are particularly welcome:

- a path where a file outside the documented directories is written
- a way to make `rollback` destroy data it cannot restore
- command injection through a Steam manifest, a wallpaper title, or a filename

## Not vulnerabilities here

`linux-wallpaperengine` renders untrusted Workshop content — shaders, scenes,
and CEF-hosted web wallpapers — with your user's privileges. That risk belongs
to that project and to Wallpaper Engine; this tool neither adds to nor reduces
it. Report such issues upstream.

## Supported versions

The tip of `main`. This project is small enough that backporting to older tags
would be theatre rather than maintenance.
