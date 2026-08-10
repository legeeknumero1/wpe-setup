#!/usr/bin/env bash
#
# wpe-setup — set up Wallpaper Engine wallpapers on Linux, in one command.
#
# Nothing is written to disk before a restorable backup exists, and every file
# this tool touches is recorded so `rollback` can put the machine back exactly
# as it was. Paths are always discovered, never assumed: Steam, the Workshop
# content, the engine assets and the compositor are all probed at runtime.
#
# Usage:
#   wpe-setup.sh              interactive menu
#   wpe-setup.sh check        audit prerequisites, change nothing
#   wpe-setup.sh install      back up, then configure
#   wpe-setup.sh rollback     restore the previous state
#   wpe-setup.sh status       what is currently configured
#
# License: MIT

set -uo pipefail

readonly WPE_VERSION="1.0.0"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wpe-setup"
readonly BACKUP_DIR="$STATE_DIR/backups"
readonly STATE_FILE="$STATE_DIR/state.env"
readonly LOG_FILE="$STATE_DIR/wpe-setup.log"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wpe"
readonly BIN_DIR="$HOME/.local/bin"

# Steam AppID of Wallpaper Engine. Its Workshop items live under
# steamapps/workshop/content/<this>, its shader/material assets under
# steamapps/common/wallpaper_engine/assets.
readonly WE_APPID=431960

# ─────────────────────────────────────────────────────────────────────────────
#  Output helpers
# ─────────────────────────────────────────────────────────────────────────────

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    readonly C_RESET=$'\033[0m'  C_BOLD=$'\033[1m'   C_DIM=$'\033[2m'
    readonly C_RED=$'\033[31m'   C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'  C_CYAN=$'\033[36m'
else
    readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

log()  { printf '%s [%s] %s\n' "$(date -Is)" "${1}" "${2}" >> "$LOG_FILE" 2>/dev/null || true; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; log INFO "$1"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; log WARN "$1"; }
bad()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1"; log ERROR "$1"; }
info() { printf '  %s·%s %s\n' "$C_DIM" "$C_RESET" "$1"; }
head1() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"; }
die()  { printf '\n%sError:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$1" >&2; log FATAL "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  Detection — every path is probed, none is hardcoded
# ─────────────────────────────────────────────────────────────────────────────

# Steam can be a native package, a Flatpak or a Snap, and users relocate their
# libraries freely. Collect every plausible root, then let libraryfolders.vdf
# tell us about the extra drives.
detect_steam_roots() {
    local -a candidates=(
        "${XDG_DATA_HOME:-$HOME/.local/share}/Steam"
        "$HOME/.steam/steam"
        "$HOME/.steam/root"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
        "$HOME/snap/steam/common/.local/share/Steam"
        "/usr/local/share/Steam"
    )
    local -a roots=()
    local c

    for c in "${candidates[@]}"; do
        [ -d "$c/steamapps" ] && roots+=("$(readlink -f "$c")")
    done

    # Additional library folders declared by Steam itself.
    local vdf root extra
    for root in "${roots[@]}"; do
        vdf="$root/steamapps/libraryfolders.vdf"
        [ -f "$vdf" ] || continue
        while IFS= read -r extra; do
            [ -n "$extra" ] && [ -d "$extra/steamapps" ] && roots+=("$(readlink -f "$extra")")
        done < <(sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf" 2>/dev/null)
    done

    printf '%s\n' "${roots[@]}" | awk 'NF && !seen[$0]++'
}

detect_workshop_dir() {
    local root
    while IFS= read -r root; do
        [ -d "$root/steamapps/workshop/content/$WE_APPID" ] && {
            echo "$root/steamapps/workshop/content/$WE_APPID"; return 0
        }
    done < <(detect_steam_roots)
    return 1
}

detect_assets_dir() {
    local root
    while IFS= read -r root; do
        [ -d "$root/steamapps/common/wallpaper_engine/assets" ] && {
            echo "$root/steamapps/common/wallpaper_engine/assets"; return 0
        }
    done < <(detect_steam_roots)
    return 1
}

count_wallpapers() {
    local ws; ws="$(detect_workshop_dir)" || { echo 0; return; }
    find "$ws" -maxdepth 2 -name project.json 2>/dev/null | wc -l
}

detect_engine() {
    command -v linux-wallpaperengine 2>/dev/null && return 0
    local p
    for p in /opt/linux-wallpaperengine/linux-wallpaperengine \
             /usr/local/bin/linux-wallpaperengine \
             "$HOME/.local/bin/linux-wallpaperengine"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

# Which compositor are we on, and can it host a wallpaper layer at all?
detect_compositor() {
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then echo hyprland
    elif [ -n "${SWAYSOCK:-}" ];                  then echo sway
    elif [ -n "${NIRI_SOCKET:-}" ];               then echo niri
    elif [ -n "${WAYFIRE_SOCKET:-}" ];            then echo wayfire
    elif [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        case "${XDG_CURRENT_DESKTOP:-}" in
            *GNOME*) echo gnome ;;
            *KDE*|*plasma*|*Plasma*) echo plasma ;;
            *river*|*River*) echo river ;;
            *) echo wayland-unknown ;;
        esac
    elif [ "${XDG_SESSION_TYPE:-}" = "x11" ];     then echo x11
    else echo unknown
    fi
}

# 0 = layer-shell wallpapers work, 1 = unknown, 2 = impossible, 3 = manual setup.
#
# GNOME's Mutter does not implement wlr-layer-shell at all, and no installer can
# work around that. KWin does implement it, but Plasma's desktop containment
# draws above the background layer, so a wallpaper put there is simply hidden:
# Plasma needs window mode plus KWin window rules, which cannot be automated
# from here and costs the desktop icons. Both are stated up front rather than
# failing mysteriously later.
compositor_supported() {
    case "$1" in
        hyprland|sway|niri|wayfire|river|x11) return 0 ;;
        plasma) return 3 ;;
        gnome)  return 2 ;;
        *) return 1 ;;
    esac
}

# One --screen-root per output. Every compositor exposes this differently.
detect_outputs() {
    case "$(detect_compositor)" in
        hyprland)
            command -v hyprctl >/dev/null && hyprctl monitors -j 2>/dev/null | jq -r '.[].name' ;;
        sway)
            command -v swaymsg >/dev/null && swaymsg -t get_outputs -r 2>/dev/null | jq -r '.[].name' ;;
        *)
            if command -v wlr-randr >/dev/null 2>&1; then
                wlr-randr 2>/dev/null | awk '/^[^ \t]/{print $1}' | head -20
            elif command -v xrandr >/dev/null 2>&1; then
                xrandr --query 2>/dev/null | awk '/ connected/{print $1}'
            fi ;;
    esac
}

detect_audio_server() {
    if pgrep -x pipewire >/dev/null 2>&1; then echo pipewire
    elif pgrep -x pulseaudio >/dev/null 2>&1; then echo pulseaudio
    else echo none
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Prerequisite audit
# ─────────────────────────────────────────────────────────────────────────────

# Set by run_check for the caller.
CHECK_BLOCKERS=0
CHECK_WARNINGS=0

run_check() {
    CHECK_BLOCKERS=0
    CHECK_WARNINGS=0

    head1 "Prerequisites"

    local comp; comp="$(detect_compositor)"
    compositor_supported "$comp"
    case $? in
        0) ok "Compositor: $comp (wlr-layer-shell available)" ;;
        2) bad "Compositor: GNOME — does not implement wlr-layer-shell."
           info "The engine cannot draw a wallpaper under GNOME Wayland."
           info "An X11 session or a wlroots compositor is required."
           CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1)) ;;
        3) warn "Compositor: KDE Plasma — manual setup required."
           info "KWin implements layer-shell, but Plasma's desktop containment"
           info "draws above the background layer, hiding the wallpaper."
           info "See Almamu/linux-wallpaperengine discussion #472 (window mode"
           info "plus KWin window rules, at the cost of desktop icons)."
           CHECK_WARNINGS=$((CHECK_WARNINGS + 1)) ;;
        *) warn "Unrecognised compositor: $comp — rendering is not guaranteed"
           CHECK_WARNINGS=$((CHECK_WARNINGS + 1)) ;;
    esac

    # Explicit if/else, not A && B || C: these branches decide whether install is
    # allowed to proceed, and the short form would run the failure branch if the
    # success branch ever returned non-zero.
    local engine
    if engine="$(detect_engine)"; then
        ok "Engine: $engine"
    else
        bad "linux-wallpaperengine not found"
        info "Arch/CachyOS : yay -S linux-wallpaperengine-git"
        info "Others: https://github.com/Almamu/linux-wallpaperengine"
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    local roots; roots="$(detect_steam_roots)"
    if [ -n "$roots" ]; then
        ok "Steam: $(echo "$roots" | wc -l) library(ies)"
        echo "$roots" | while IFS= read -r r; do info "$r"; done
    else
        bad "No Steam library found"
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    local assets
    if assets="$(detect_assets_dir)"; then
        ok "Wallpaper Engine assets: $assets"
    else
        bad "Wallpaper Engine is not installed through Steam"
        info "'scene' wallpapers need its shaders and materials."
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    local n; n="$(count_wallpapers)"
    if [ "$n" -gt 0 ]; then
        ok "Workshop wallpapers: $n"
    else
        bad "No wallpaper downloaded"
        info "Subscribe to wallpapers in the Steam Workshop, then run again."
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    local audio; audio="$(detect_audio_server)"
    if [ "$audio" = "pipewire" ]; then
        ok "Audio: PipeWire — --noautomute will be applied (mandatory)"
    else
        ok "Audio: $audio"
    fi

    local dep missing=()
    for dep in jq find awk; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
    if [ ${#missing[@]} -eq 0 ]; then
        ok "Dependencies: jq, find, awk"
    else
        bad "Missing: ${missing[*]}"
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    if command -v matugen >/dev/null 2>&1; then
        ok "matugen present — colour sync available"
    else
        info "matugen missing — colour sync will stay off (optional)"
    fi

    local plugins; plugins="$(available_plugins)"
    if [ -n "$plugins" ]; then
        local p
        while IFS= read -r p; do
            ok "Integration available: $(basename "$p" .sh)"
        done <<< "$plugins"
    fi

    head1 "Verdict"
    if [ "$CHECK_BLOCKERS" -gt 0 ]; then
        bad "$CHECK_BLOCKERS critical prerequisite(s) missing"
        return 1
    fi
    [ "$CHECK_WARNINGS" -gt 0 ] && warn "$CHECK_WARNINGS warning(s)"
    ok "Everything is ready"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  Backup / rollback
# ─────────────────────────────────────────────────────────────────────────────

# Files this tool may create or modify. Only those that exist are archived, and
# the list is stored with the backup so rollback knows what to restore *and*
# what to delete (files that did not exist before must not survive a rollback).
backup_targets() {
    printf '%s\n' \
        "$CONFIG_DIR" \
        "$BIN_DIR/wpe"

    # A plugin that will edit existing dotfiles must have those files archived
    # too, otherwise rollback would restore only half the machine.
    local plugin
    while IFS= read -r plugin; do
        "$plugin" targets 2>/dev/null
    done < <(available_plugins)
}

plugin_dir() { echo "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/plugins"; }

# Plugins that both exist and apply to this machine.
available_plugins() {
    local dir; dir="$(plugin_dir)"
    [ -d "$dir" ] || return 0
    local p
    for p in "$dir"/*.sh; do
        [ -x "$p" ] || continue
        "$p" detect >/dev/null 2>&1 && echo "$p"
    done
}

create_backup() {
    mkdir -p "$BACKUP_DIR"
    local stamp archive listing
    stamp="$(date +%Y%m%d-%H%M%S)"
    archive="$BACKUP_DIR/$stamp.tar.gz"
    listing="$BACKUP_DIR/$stamp.files"

    local -a existing=()
    local t
    while IFS= read -r t; do
        [ -e "$t" ] && existing+=("$t")
    done < <(backup_targets)

    # Record every target, present or not: absence is information rollback needs.
    backup_targets > "$listing"

    # A single archive format, always relative to /: a second format would make
    # extraction ambiguous, and guessing wrong on restore writes files to the
    # wrong place while the originals are already gone.
    if [ ${#existing[@]} -gt 0 ]; then
        tar czf "$archive" -C / "${existing[@]#/}" 2>/dev/null \
            || { rm -f "$archive" "$listing"; return 1; }
    else
        # Nothing pre-existing: an empty marker still lets rollback clean up.
        tar czf "$archive" -T /dev/null 2>/dev/null \
            || { rm -f "$archive" "$listing"; return 1; }
    fi

    # An archive that cannot be listed cannot be restored. Better to fail here,
    # before anything is modified, than at rollback time when it is too late.
    if ! tar tzf "$archive" >/dev/null 2>&1; then
        rm -f "$archive" "$listing"
        return 1
    fi

    echo "$archive"
}

do_rollback() {
    head1 "Rollback"

    [ -d "$BACKUP_DIR" ] || die "No backup found in $BACKUP_DIR"

    # The pristine snapshot recorded at first install, never a later one: after a
    # second install the newest archive contains the *installed* state, and
    # restoring it would be a no-op dressed up as a rollback.
    local archive=""
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        [ -n "${BACKUP:-}" ] && [ -f "${BACKUP:-}" ] && archive="$BACKUP"
    fi
    [ -n "$archive" ] || archive="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' | sort | head -1)"
    [ -n "$archive" ] || die "No backup found"

    local listing="${archive%.tar.gz}.files"

    # Refuse to touch anything until the archive is proven readable.
    tar tzf "$archive" >/dev/null 2>&1 \
        || die "Unreadable backup ($archive) — nothing was deleted"

    info "Backup: $(basename "$archive")"
    printf '\n  Restore this state? [y/N] '
    local reply; read -r reply
    case "$reply" in [oO]|[yY]) ;; *) info "Cancelled"; return 0 ;; esac

    # Prove the archive really extracts before removing anything: listing it is
    # not enough, and deleting first only to discover extraction fails would
    # destroy the user's files with nothing left to put back. The staged copy is
    # a rehearsal, discarded immediately.
    local staging
    staging="$(mktemp -d "$BACKUP_DIR/restore.XXXXXX")" \
        || die "Cannot stage the restore — nothing was deleted"

    if ! tar xzf "$archive" -C "$staging" 2>/dev/null; then
        rm -rf "$staging"
        die "Extraction failed — nothing was deleted"
    fi
    rm -rf "$staging"

    # Let integrations remove what they created before the config is restored.
    local plugin
    while IFS= read -r plugin; do
        "$plugin" cleanup >/dev/null 2>&1 || true
    done < <(available_plugins)

    if [ -f "$listing" ]; then
        local t
        while IFS= read -r t; do
            [ -n "$t" ] && rm -rf "$t"
        done < "$listing"
    fi

    # tar rather than cp: paths are stored relative to /, and cp -a reports
    # failure when it cannot stamp attributes onto pre-existing parent
    # directories even though every file was copied correctly.
    tar xzf "$archive" -C / 2>/dev/null \
        || die "Incomplete restore — the archive $archive was kept"

    rm -f "$STATE_FILE"
    ok "State restored"
    info "The engine and system packages were left untouched."
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  Install
# ─────────────────────────────────────────────────────────────────────────────

write_runtime() {
    local workshop assets
    workshop="$(detect_workshop_dir)" || return 1
    assets="$(detect_assets_dir)"     || assets=""

    mkdir -p "$CONFIG_DIR" "$BIN_DIR"

    cat > "$CONFIG_DIR/config" <<EOF
# Written by wpe-setup $WPE_VERSION on $(date -Is)
# Paths are re-detected at runtime; these are cached hints only.
WORKSHOP_DIR="$workshop"
ASSETS_DIR="$assets"
WALLPAPER_ID=""
FPS=30
SCALING="fill"
SILENT=1
SYNC_COLORS=$(command -v matugen >/dev/null 2>&1 && echo 1 || echo 0)
EOF

    # readlink -f, not a bare dirname: installing this script through a symlink
    # in PATH would otherwise look for lib/ next to the link, not the source.
    cp "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/wpe" "$BIN_DIR/wpe" 2>/dev/null \
        || return 1
    chmod +x "$BIN_DIR/wpe"
    return 0
}

do_install() {
    head1 "Pre-flight check"
    if ! run_check; then
        printf '\n%s  Critical prerequisites are missing.%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
        printf '  Continuing is %sstrongly discouraged%s: the resulting setup\n' "$C_BOLD" "$C_RESET"
        printf '  will not work, and you may disturb your session.\n'
        printf '\n  Continue anyway? [y/N] '
        local reply; read -r reply
        case "$reply" in [oO]|[yY]) warn "Forced by the user" ;; *) info "Cancelled — nothing was changed"; return 1 ;; esac
    fi

    # The rollback reference must stay the state of the machine *before* this
    # tool ever ran. Re-installing takes a fresh snapshot for safety, but the
    # pristine one keeps its role, otherwise rollback would restore an
    # already-installed system.
    local pristine=""
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        [ -n "${BACKUP:-}" ] && [ -f "${BACKUP:-}" ] && pristine="$BACKUP"
    fi

    head1 "Backup"
    local archive
    archive="$(create_backup)" || die "Backup failed — nothing was changed"
    ok "Backup created: $archive"

    if [ -n "$pristine" ]; then
        info "Restore point kept: $(basename "$pristine")"
        archive="$pristine"
    else
        info "'wpe-setup rollback' restores exactly this state."
    fi

    head1 "Install"
    write_runtime || die "Install failed — run 'wpe-setup rollback'"
    ok "Installed the 'wpe' command in $BIN_DIR"
    ok "Wrote configuration to $CONFIG_DIR/config"

    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
INSTALLED_AT="$(date -Is)"
VERSION="$WPE_VERSION"
BACKUP="$archive"
COMPOSITOR="$(detect_compositor)"
EOF

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR is not in your PATH"
           info "Add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac

    local plugins; plugins="$(available_plugins)"
    if [ -n "$plugins" ]; then
        head1 "Detected integrations"
        local p
        while IFS= read -r p; do
            info "$(basename "$p" .sh)"
        done <<< "$plugins"
        printf '\n  Enable them? They wire your wallpapers straight into\n'
        printf '  your desktop environment. [Y/n] '
        local reply; read -r reply
        case "$reply" in
            [nN]) info "Integrations skipped" ;;
            *) while IFS= read -r p; do
                   head1 "Integration: $(basename "$p" .sh)"
                   "$p" install || warn "integration failed — 'wpe-setup rollback' undoes everything"
               done <<< "$plugins" ;;
        esac
    fi

    head1 "Done"
    info "wpe list          available wallpapers"
    info "wpe random        apply a random one"
    info "wpe set <id>      apply a specific one"
    info "wpe watch         keep the engine alive (put this in your autostart)"
    return 0
}

do_status() {
    head1 "Status"
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        ok "Installed on ${INSTALLED_AT:-?} (version ${VERSION:-?})"
        info "Backup: ${BACKUP:-none}"
    else
        info "wpe-setup is not installed on this machine"
    fi
    info "Compositor: $(detect_compositor)"
    info "Wallpapers: $(count_wallpapers)"
    if pgrep -x linux-wallpaper >/dev/null 2>&1; then
        ok "Engine running"
    else
        info "Engine stopped"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Menu
# ─────────────────────────────────────────────────────────────────────────────

banner() {
    printf '\n%s  wpe-setup %s%s — Wallpaper Engine on Linux, in one command\n' \
        "$C_BOLD$C_BLUE" "$WPE_VERSION" "$C_RESET"
}

menu() {
    banner
    printf '\n  %s1%s  Check prerequisites %s(changes nothing)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s2%s  Install and configure\n' "$C_BOLD" "$C_RESET"
    printf '  %s3%s  Roll back %s(restore the backup)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s4%s  Current status\n' "$C_BOLD" "$C_RESET"
    printf '  %s5%s  Quit\n' "$C_BOLD" "$C_RESET"
    printf '\n  Your choice [1-5]: '

    local choice; read -r choice
    case "$choice" in
        1) run_check || true ;;
        2) do_install || true ;;
        3) do_rollback || true ;;
        4) do_status ;;
        5) return 0 ;;
        *) warn "Invalid choice" ;;
    esac
}

main() {
    mkdir -p "$STATE_DIR"
    case "${1:-menu}" in
        check)    run_check ;;
        install)  do_install ;;
        rollback) do_rollback ;;
        status)   do_status ;;
        version)  echo "wpe-setup $WPE_VERSION" ;;
        menu|"")  menu ;;
        *)        printf 'usage: %s {check|install|rollback|status|version}\n' "$(basename "$0")" >&2; exit 1 ;;
    esac
}

main "$@"
