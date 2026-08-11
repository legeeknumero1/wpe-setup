#!/usr/bin/env bash
#
# wpe-setup test suite.
#
# No framework: the project's promise is that bash and coreutils are all you
# need, and a test suite that contradicts that would be a poor advertisement.
#
# Every test runs against a throwaway HOME containing a synthetic Steam tree, so
# nothing here can read or touch the machine it runs on. Each case corresponds
# to a failure that actually happened during development — a corrupt backup that
# deleted files it could not restore, an empty id that passed validation because
# it resolved to the parent directory, previews that outlived the wallpapers
# they belonged to.
#
# Usage: tests/run.sh [name-filter]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly WE_APPID=431960

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    readonly GREEN=$'\033[32m' RED=$'\033[31m' DIM=$'\033[2m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    readonly GREEN='' RED='' DIM='' BOLD='' RESET=''
fi

PASSED=0
FAILED=0
FILTER="${1:-}"
SANDBOX=""

# ─── Harness ─────────────────────────────────────────────────────────────────

fail() { printf '    %s✗%s %s\n' "$RED" "$RESET" "$1"; FAILED=$((FAILED + 1)); }
pass() { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$1"; PASSED=$((PASSED + 1)); }

assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else
        fail "$3"
        printf '      expected: %s\n      actual:   %s\n' "$2" "$1"
    fi
}

assert_ok()      { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2 (exit $1)"; fi; }
assert_fails()   { if [ "$1" -ne 0 ]; then pass "$2"; else fail "$2 (unexpectedly succeeded)"; fi; }
assert_exists()  { if [ -e "$1" ]; then pass "$2"; else fail "$2 (missing: $1)"; fi; }
assert_absent()  { if [ ! -e "$1" ]; then pass "$2"; else fail "$2 (still present: $1)"; fi; }

# A disposable HOME with a synthetic Steam library. steam_root is where the
# library lives relative to HOME, so a test can put it somewhere no candidate
# list would ever guess.
new_sandbox() {
    local steam_root="${1:-.local/share/Steam}" wallpapers="${2:-3}"
    SANDBOX="$(mktemp -d)"

    local lib="$SANDBOX/$steam_root"
    mkdir -p "$lib/steamapps/common/wallpaper_engine/assets"
    mkdir -p "$lib/steamapps/workshop/content/$WE_APPID"

    local i
    for i in $(seq 1 "$wallpapers"); do
        local d="$lib/steamapps/workshop/content/$WE_APPID/10000$i"
        mkdir -p "$d"
        printf '{"title":"Test %s","type":"scene","preview":"preview.jpg"}\n' "$i" > "$d/project.json"
        printf 'not-a-real-image' > "$d/preview.jpg"
    done

    printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$lib" \
        > "$lib/steamapps/libraryfolders.vdf"

    mkdir -p "$SANDBOX/.config" "$SANDBOX/.local/state" "$SANDBOX/.local/bin" "$SANDBOX/Pictures/Wallpapers"

    # A stub engine, so `check` sees its prerequisite satisfied. CI runners have
    # no linux-wallpaperengine, and without this `install` would stop at the
    # confirmation prompt and every later assertion would fail for the wrong
    # reason. Nothing here ever renders, so a stub is enough.
    mkdir -p "$SANDBOX/bin"
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/linux-wallpaperengine"
    chmod +x "$SANDBOX/bin/linux-wallpaperengine"

    echo "$SANDBOX"
}

drop_sandbox() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; SANDBOX=""; }

# Runs a command against a sandbox with nothing inherited from the host: no
# XDG_* pointing outside it, no WALLPAPER_DIR from the developer's desktop.
# Leaking either makes a test read real files and pass or fail for reasons that
# have nothing to do with the code.
run_in() {
    local home="$1"; shift
    env -i \
        HOME="$home" \
        PATH="$home/bin:/usr/local/bin:/usr/bin:/bin" \
        NO_COLOR=1 \
        "$@"
}

setup_in() {
    local home="$1"; shift
    run_in "$home" bash "$ROOT/wpe-setup.sh" "$@"
}

plugin_in() {
    local home="$1"; shift
    run_in "$home" bash "$ROOT/plugins/imperative-dots.sh" "$@"
}

# Loads wpe-setup's functions without executing the CLI.
source_lib_in() {
    local home="$1"
    # shellcheck source=/dev/null
    HOME="$home" WPE_SETUP_LIB=1 . "$ROOT/wpe-setup.sh"
}

describe() {
    [ -n "$FILTER" ] && case "$1" in *"$FILTER"*) ;; *) return 1 ;; esac
    printf '\n  %s%s%s\n' "$BOLD" "$1" "$RESET"
    return 0
}

# ─── Discovery ───────────────────────────────────────────────────────────────

test_discovery_conventional() {
    describe "discovery: conventional Steam location" || return 0
    local home; home="$(new_sandbox)"
    local found
    found="$(source_lib_in "$home" >/dev/null 2>&1; HOME="$home" detect_steam_roots 2>/dev/null | head -1)"
    assert_eq "$found" "$home/.local/share/Steam" "finds the standard library"
    drop_sandbox
}

test_discovery_relocated() {
    describe "discovery: library on another drive" || return 0
    # No candidate list contains this path; only the bounded scan can find it.
    local home; home="$(new_sandbox "Games/SecondSSD/SteamLibrary")"
    local found
    found="$(source_lib_in "$home" >/dev/null 2>&1; HOME="$home" detect_steam_roots 2>/dev/null | head -1)"
    assert_eq "$found" "$home/Games/SecondSSD/SteamLibrary" "finds a relocated library"

    local workshop
    workshop="$(source_lib_in "$home" >/dev/null 2>&1; HOME="$home" detect_workshop_dir 2>/dev/null)"
    assert_eq "$workshop" "$home/Games/SecondSSD/SteamLibrary/steamapps/workshop/content/$WE_APPID" \
        "resolves the workshop directory through it"
    drop_sandbox
}

test_discovery_absent() {
    describe "discovery: no Steam anywhere" || return 0
    local home; home="$(mktemp -d)"
    local start elapsed rc
    start=$(date +%s)
    ( source_lib_in "$home" >/dev/null 2>&1; HOME="$home" detect_steam_roots >/dev/null 2>&1 )
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    assert_fails "$rc" "reports failure instead of inventing a path"
    if [ "$elapsed" -lt 40 ]; then
        pass "gives up promptly (${elapsed}s, scan is time-bounded)"
    else
        fail "took ${elapsed}s — the scan timeout is not holding"
    fi
    rm -rf "$home"
}

# ─── Runtime validation ──────────────────────────────────────────────────────

test_empty_id_rejected() {
    describe "runtime: an empty wallpaper id is rejected" || return 0
    # An empty library: `random` then picks nothing and passes "" onward. This
    # is the path that mattered — "$WORKSHOP_DIR/" is a real directory, so a
    # plain -d check accepts the empty id and persists a broken config.
    local home; home="$(new_sandbox ".local/share/Steam" 0)"
    mkdir -p "$home/.config/wpe"
    cat > "$home/.config/wpe/config" <<EOF
WORKSHOP_DIR="$home/.local/share/Steam/steamapps/workshop/content/$WE_APPID"
ASSETS_DIR=""
WALLPAPER_ID=""
FPS=30
SCALING="fill"
SILENT=1
SYNC_COLORS=0
MATUGEN_HOOK=""
EOF
    local out
    out="$(run_in "$home" bash "$ROOT/lib/wpe" random 2>&1)"
    case "$out" in
        *"no id given"*) pass "'random' on an empty library refuses the empty id" ;;
        *) fail "accepted an empty id: $out" ;;
    esac
    assert_eq "$(grep -c '^WALLPAPER_ID=""' "$home/.config/wpe/config")" "1" \
        "leaves the stored configuration untouched"

    # The CLI rejects it earlier, before the function is ever reached.
    out="$(run_in "$home" bash "$ROOT/lib/wpe" set "" 2>&1)"
    case "$out" in
        *"usage: wpe set"*) pass "'set \"\"' is caught by the argument guard" ;;
        *) fail "unexpected output from set \"\": $out" ;;
    esac
    drop_sandbox
}

# ─── Backup and rollback ─────────────────────────────────────────────────────

test_rollback_refuses_corrupt_backup() {
    describe "rollback: a corrupt backup deletes nothing" || return 0
    local home; home="$(new_sandbox)"
    local backups="$home/.local/state/wpe-setup/backups"
    mkdir -p "$backups" "$home/canary"

    printf 'irreplaceable\n' > "$home/canary/keep.txt"
    printf 'this is not a gzip stream\n' > "$backups/20260101-000000.tar.gz"
    printf '%s\n' "$home/canary/keep.txt" > "$backups/20260101-000000.files"

    local out
    out="$(printf 'y\n' | setup_in "$home" rollback 2>&1)"
    case "$out" in
        *"Unreadable backup"*) pass "refuses to proceed" ;;
        *) fail "did not detect the corrupt archive" ;;
    esac
    assert_exists "$home/canary/keep.txt" "leaves the targeted file intact"
    drop_sandbox
}

test_rollback_restores_and_prunes() {
    describe "rollback: restores what existed, removes what it created" || return 0
    local home; home="$(new_sandbox)"

    # A file wpe-setup will archive and later restore.
    mkdir -p "$home/.config/wpe"
    printf 'ORIGINAL CONTENT\n' > "$home/.config/wpe/pre-existing"
    local before; before="$(md5sum "$home/.config/wpe/pre-existing" | cut -d' ' -f1)"

    setup_in "$home" install >/dev/null 2>&1
    assert_exists "$home/.local/bin/wpe" "install places the runtime"

    printf 'y\n' | setup_in "$home" rollback >/dev/null 2>&1
    assert_absent "$home/.local/bin/wpe" "removes what it created"

    local after; after="$(md5sum "$home/.config/wpe/pre-existing" 2>/dev/null | cut -d' ' -f1)"
    assert_eq "$after" "$before" "restores a pre-existing file byte-for-byte"
    drop_sandbox
}

test_reinstall_keeps_pristine_restore_point() {
    describe "rollback: re-installing keeps the original restore point" || return 0
    local home; home="$(new_sandbox)"

    setup_in "$home" install >/dev/null 2>&1
    sleep 1              # timestamps name the archives; force a distinct one
    setup_in "$home" install >/dev/null 2>&1

    local count recorded oldest
    count="$(find "$home/.local/state/wpe-setup/backups" -name '*.tar.gz' | wc -l)"
    assert_eq "$count" "2" "takes a fresh snapshot on re-install"

    recorded="$(sed -n 's/^BACKUP="\(.*\)"$/\1/p' "$home/.local/state/wpe-setup/state.env")"
    oldest="$(find "$home/.local/state/wpe-setup/backups" -name '*.tar.gz' | sort | head -1)"
    assert_eq "$recorded" "$oldest" "still points rollback at the pristine one"
    drop_sandbox
}

# ─── Plugin contract ─────────────────────────────────────────────────────────

test_plugin_contract() {
    describe "plugins: every plugin answers the full contract" || return 0
    local p sub
    for p in "$ROOT"/plugins/*.sh; do
        for sub in detect targets install sync cleanup status; do
            if grep -qE "^ *$sub\)" "$p"; then
                pass "$(basename "$p") handles '$sub'"
            else
                fail "$(basename "$p") does not handle '$sub'"
            fi
        done
    done
}

test_plugin_refuses_unknown_file() {
    describe "plugins: an unrecognised file is left alone" || return 0
    local home; home="$(new_sandbox)"
    local picker="$home/.config/hypr/scripts/quickshell/wallpaper/WallpaperPicker.qml"
    mkdir -p "$(dirname "$picker")" "$home/.config/hypr/scripts"

    printf 'this file looks nothing like the real picker\n' > "$picker"
    printf 'nor does this\n' > "$home/.config/hypr/scripts/qs_manager.sh"
    printf '{"wallpaperDir":"%s/Pictures/Wallpapers"}\n' "$home" > "$home/.config/hypr/settings.json"
    local before; before="$(md5sum "$picker" | cut -d' ' -f1)"

    local out
    out="$(plugin_in "$home" install 2>&1)"
    case "$out" in
        *"unrecognised picker layout"*) pass "warns instead of patching blind" ;;
        *) fail "did not report an unrecognised layout" ;;
    esac
    assert_eq "$(md5sum "$picker" | cut -d' ' -f1)" "$before" "leaves the file byte-identical"
    drop_sandbox
}

test_plugin_prunes_orphans() {
    describe "plugins: previews of unsubscribed wallpapers are pruned" || return 0
    local home; home="$(new_sandbox)"
    mkdir -p "$home/.config/hypr/scripts/quickshell/wallpaper"
    printf 'x\n' > "$home/.config/hypr/scripts/quickshell/wallpaper/WallpaperPicker.qml"
    printf 'x\n' > "$home/.config/hypr/scripts/qs_manager.sh"
    printf '{"wallpaperDir":"%s/Pictures/Wallpapers"}\n' "$home" > "$home/.config/hypr/settings.json"

    local wp="$home/Pictures/Wallpapers"
    printf 'stale\n' > "$wp/0we_999999999.jpg"     # no longer in the workshop
    printf 'mine\n'  > "$wp/my-own-wallpaper.jpg"  # belongs to the user

    plugin_in "$home" sync >/dev/null 2>&1

    assert_absent "$wp/0we_999999999.jpg" "removes the orphaned preview"
    assert_exists "$wp/my-own-wallpaper.jpg" "never touches the user's own wallpapers"
    assert_eq "$(find "$wp" -name '0we_*' | wc -l)" "3" "mirrors the three subscribed wallpapers"
    drop_sandbox
}

test_plugin_idempotent() {
    describe "plugins: running twice changes nothing the second time" || return 0
    local home; home="$(new_sandbox)"
    local picker="$home/.config/hypr/scripts/quickshell/wallpaper/WallpaperPicker.qml"
    mkdir -p "$(dirname "$picker")"

    # shellcheck disable=SC2016  # literal template text, must not expand
    printf 'const fullScript = `\n  original body\n`;\n' > "$picker"
    printf 'x\n' > "$home/.config/hypr/scripts/qs_manager.sh"
    printf '{"wallpaperDir":"%s/Pictures/Wallpapers"}\n' "$home" > "$home/.config/hypr/settings.json"

    plugin_in "$home" install >/dev/null 2>&1
    local first; first="$(md5sum "$picker" | cut -d' ' -f1)"
    plugin_in "$home" install >/dev/null 2>&1
    local second; second="$(md5sum "$picker" | cut -d' ' -f1)"

    assert_eq "$second" "$first" "the picker is patched exactly once"
    assert_eq "$(grep -c 'wpe-setup:imperative-dots' "$picker")" "1" "exactly one marker"
    drop_sandbox
}

# ─── Runner ──────────────────────────────────────────────────────────────────

main() {
    printf '%swpe-setup test suite%s\n' "$BOLD" "$RESET"
    printf '%s%s%s\n' "$DIM" "$ROOT" "$RESET"

    test_discovery_conventional
    test_discovery_relocated
    test_discovery_absent
    test_empty_id_rejected
    test_rollback_refuses_corrupt_backup
    test_rollback_restores_and_prunes
    test_reinstall_keeps_pristine_restore_point
    test_plugin_contract
    test_plugin_refuses_unknown_file
    test_plugin_prunes_orphans
    test_plugin_idempotent

    printf '\n  %s%d passed%s' "$GREEN" "$PASSED" "$RESET"
    [ "$FAILED" -gt 0 ] && printf ', %s%d failed%s' "$RED" "$FAILED" "$RESET"
    printf '\n\n'

    [ "$FAILED" -eq 0 ]
}

trap drop_sandbox EXIT
main "$@"
