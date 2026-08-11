# Contributing

Bug reports from compositors other than Hyprland are the most useful thing you
can send. Everything else is implemented from documented interfaces and tested
in sandboxes, but never on real hardware — so "it works on river" is a genuinely
valuable report, and so is "it does not".

## Running the tests

```sh
./tests/run.sh              # everything
./tests/run.sh rollback     # only cases whose name contains "rollback"
```

The suite needs no Steam, no compositor and no wallpapers: every case builds a
throwaway `HOME` with a synthetic Steam tree, so it cannot read or modify the
machine it runs on.

Each case exists because something actually broke during development. If you fix
a bug, add the case that would have caught it — that is the bar here, not
coverage percentages.

## What CI enforces

Four gates, all runnable locally before you push:

```sh
shellcheck -s bash -S style wpe-setup.sh lib/wpe plugins/*.sh tests/run.sh
for f in wpe-setup.sh lib/wpe plugins/*.sh tests/run.sh; do bash -n "$f"; done
./tests/run.sh
grep -nE '/home/[a-z]+/|/Users/[a-z]+/' wpe-setup.sh lib/wpe plugins/*.sh   # must find nothing
```

That last one is not pedantry. Discovering paths instead of assuming them is the
point of this tool, so a literal home directory in the source is a regression.

## House rules

**No hardcoded paths.** Steam moves; users relocate libraries, use Flatpak, use
Snap. Probe, then verify what you found.

**Nothing is written before a backup exists.** If you add a step that touches a
user's files, it belongs in `backup_targets` — or, if it *creates* files, in the
plugin's `cleanup`. A rollback that leaves debris behind is not a rollback.

**Never `pkill -f`.** It matches this project's own command lines. Use `pkill -x`
against the truncated process name.

**Explain the why, not the what.** A comment saying what a line does is noise;
one saying why the obvious approach was wrong is what stops the next person
reverting your fix.

## Writing a plugin

A plugin is one executable in `plugins/` answering six subcommands:

| Subcommand | Contract |
|---|---|
| `detect` | exit 0 if this setup is present on the machine |
| `targets` | list every **pre-existing** file it will modify, one per line |
| `install` | apply the integration, idempotently |
| `sync` | re-mirror external state without touching patched files |
| `cleanup` | remove the files it created, by name |
| `status` | report what is currently applied |

`targets` and `cleanup` cover different things and both are required. Files you
*edit* are archived from `targets` and restored on rollback; files you *create*
are not in that archive and must be removed by `cleanup`. Deleting the directory
that contains them is not acceptable — the user's own files live there too.

Patches must be anchored on text verified to exist first, and skipped with a
warning when it does not. Upstream projects change; a patch applied blind
corrupts a working configuration.

## Commits

Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, `refactor:`). Explain in
the body what was wrong and why the fix is the right shape — the log is the part
of this project that outlives the code.
