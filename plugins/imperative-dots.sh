#!/usr/bin/env bash
#
# wpe-setup plugin — imperative-dots (https://github.com/ilyamiro/imperative-dots)
#
# Exposes every Wallpaper Engine wallpaper inside the Quickshell wallpaper
# picker, so Super+W lists animated wallpapers alongside (or instead of) the
# static ones, and selecting one hands it to linux-wallpaperengine rather than
# pushing a still frame to awww.
#
# Subcommands: detect | targets | install | cleanup | status
#
# Every patch is idempotent and anchored on text that is verified to exist
# first: when an anchor is missing (upstream changed the file), that patch is
# skipped with a warning instead of corrupting the config.

set -uo pipefail

readonly HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
readonly PICKER="$HYPR_DIR/scripts/quickshell/wallpaper/WallpaperPicker.qml"
readonly QS_MANAGER="$HYPR_DIR/scripts/qs_manager.sh"
readonly SETTINGS="$HYPR_DIR/settings.json"
readonly RELOAD_HOOK="$HYPR_DIR/scripts/quickshell/wallpaper/matugen_reload.sh"
readonly THUMB_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/wallpaper_picker"
readonly WE_APPID=431960

# Marker proving a patch was already applied, so re-running is safe.
readonly MARKER="wpe-setup:imperative-dots"

# Files this plugin creates. They live inside the user's wallpaper folder, which
# must not be wiped wholesale, so each one is recorded and removed by name.
readonly CREATED_MANIFEST="${XDG_STATE_HOME:-$HOME/.local/state}/wpe-setup/imperative-dots.created"

p_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
p_warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
p_bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
p_info() { printf '  \033[2m·\033[0m %s\n' "$1"; }

# ─────────────────────────────────────────────────────────────────────────────

plugin_detect() {
    [ -f "$PICKER" ] && [ -f "$QS_MANAGER" ] && [ -f "$SETTINGS" ]
}

# Files wpe-setup must archive before this plugin touches anything.
plugin_targets() {
    printf '%s\n' "$PICKER" "$QS_MANAGER" "$SETTINGS"
}

wallpaper_dir() {
    local dir=""
    [ -f "$SETTINGS" ] && dir="$(jq -r '.wallpaperDir // empty' "$SETTINGS" 2>/dev/null)"
    [ -z "$dir" ] && dir="${WALLPAPER_DIR:-$HOME/Pictures/Wallpapers}"
    echo "$dir"
}

workshop_dir() {
    local -a candidates=(
        "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
        "$HOME/snap/steam/common/.local/share/Steam"
    )
    local c vdf extra
    for c in "${candidates[@]}"; do
        [ -d "$c/steamapps/workshop/content/$WE_APPID" ] && {
            echo "$c/steamapps/workshop/content/$WE_APPID"; return 0; }
        vdf="$c/steamapps/libraryfolders.vdf"
        [ -f "$vdf" ] || continue
        while IFS= read -r extra; do
            [ -d "$extra/steamapps/workshop/content/$WE_APPID" ] && {
                echo "$extra/steamapps/workshop/content/$WE_APPID"; return 0; }
        done < <(sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf" 2>/dev/null)
    done
    return 1
}

# ─── 1. Expose the wallpapers as preview stills ──────────────────────────────
#
# The picker lists image files, so each wallpaper is represented by its own
# preview. The "0we_" prefix is deliberate: the picker sorts by name and most
# static wallpapers start with a digit, so "0" floats these to the top instead
# of burying them. It must not be "000_", which the picker treats as a video.

install_previews() {
    local ws dest n=0
    ws="$(workshop_dir)" || { p_bad "Workshop content not found"; return 1; }
    dest="$(wallpaper_dir)"
    mkdir -p "$dest" || return 1

    mkdir -p "$(dirname "$CREATED_MANIFEST")"
    : > "$CREATED_MANIFEST"

    local d id preview ext target
    for d in "$ws"/*/; do
        [ -f "$d/project.json" ] || continue
        id="$(basename "$d")"
        preview="$(jq -r '.preview // empty' "$d/project.json" 2>/dev/null)"
        if [ -z "$preview" ] || [ ! -f "$d/$preview" ]; then
            continue
        fi
        ext="${preview##*.}"
        target="$dest/0we_$id.$ext"
        # Real files, not symlinks: Qt's FolderListModel is not guaranteed to
        # follow links, and a picker showing nothing is impossible to diagnose.
        if cp -L -- "$d/$preview" "$target" 2>/dev/null; then
            printf '%s\n' "$target" >> "$CREATED_MANIFEST"
        fi
    done

    # Counted from disk rather than accumulated in the loop, so the number
    # reported is what actually landed.
    n="$(find "$dest" -maxdepth 1 -name '0we_*' 2>/dev/null | wc -l)"
    p_ok "$n previews exposed in $dest"
}

# ─── 2. Route picker selections to the engine ────────────────────────────────

patch_picker() {
    if grep -q "$MARKER" "$PICKER" 2>/dev/null; then
        p_info "picker already patched"
        return 0
    fi

    python3 - "$PICKER" "$MARKER" <<'PYEOF'
import re, sys

path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

# Anchor on the single place where the picker builds the shell command that
# applies a locally stored wallpaper.
anchor = 'const fullScript = `'
i = src.find(anchor)
if i == -1:
    sys.exit(2)

# Find the end of that template literal.
j = src.find('`;', i + len(anchor))
if j == -1:
    sys.exit(2)

original_body = src[i + len(anchor):j]

replacement = '''const fullScript = `
            # ''' + marker + '''
            # Wallpaper Engine entries are preview stills named 0we_<id>.<ext>.
            # Pushing one to awww would freeze a single frame on screen, so it is
            # handed to the engine instead, which renders the animated wallpaper
            # and re-derives the palette from a real rendered frame.
            WE_NAME="$(basename "${escOriginal}")"
            WE_ID="\\${WE_NAME#0we_}"
            WE_ID="\\${WE_ID%.*}"

            if [ "\\${WE_NAME}" != "\\${WE_NAME#0we_}" ] && command -v wpe >/dev/null 2>&1; then
                cp "${escOriginal}" ${paths.getCacheDir("wallpaper_picker")}/current_wallpaper.png || true
                pkill mpvpaper || true
                wpe set "\\${WE_ID}" >/dev/null 2>&1 &
            else
                pkill -x linux-wallpaper || true
''' + original_body.rstrip() + '''
            fi
        `;'''

open(path, "w", encoding="utf-8").write(src[:i] + replacement + src[j + 2:])
PYEOF

    case $? in
        0) p_ok "picker patched — 0we_ wallpapers now go to the engine" ;;
        2) p_warn "unrecognised picker layout — patch skipped (file untouched)"
           p_info "imperative-dots likely changed; please report it upstream" ;;
        *) p_bad "failed to patch the picker"; return 1 ;;
    esac
}

# ─── 3. Make thumbnail generation fast ───────────────────────────────────────
#
# Upstream builds thumbnails one at a time, and calls magick on the whole file:
# on an animated GIF that decodes and scales every single frame. With a few
# hundred wallpapers this takes many minutes on first open.

patch_thumbnails() {
    if grep -q "$MARKER" "$QS_MANAGER" 2>/dev/null; then
        p_info "thumbnail generation already optimised"
        return 0
    fi

    python3 - "$QS_MANAGER" "$MARKER" <<'PYEOF'
import sys

path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

start = src.find('        while IFS= read -r filename; do')
if start == -1:
    sys.exit(2)
end = src.find('done < <(comm -23 "$SRC_LIST"', start)
if end == -1:
    sys.exit(2)
end = src.find('\n', end) + 1

fast = '''        # ''' + marker + '''
        # One thumbnail per call, run in parallel below. Each magick stays
        # single-threaded and we run one job per core instead, which beats a
        # single multi-threaded resize at a time by a wide margin.
        gen_thumb() {
            local filename="$1"
            local img="$SRC_DIR/$filename"
            [ -f "$img" ] || return 0

            local ext="${filename##*.}"; ext="${ext,,}"

            if [ "$ext" = "webp" ]; then
                local new_img="${img%.*}.jpg"
                magick "$img[0]" "$new_img" 2>/dev/null && rm -f "$img"
                img="$new_img"; filename="$(basename "$img")"; ext="jpg"
            fi

            local thumb
            case "$ext" in
                mp4|mkv|mov|webm)
                    thumb="$THUMB_DIR/000_$filename"
                    [ -f "$THUMB_DIR/$filename" ] && rm -f "$THUMB_DIR/$filename"
                    [ -f "$thumb" ] || ffmpeg -y -ss 00:00:05 -i "$img" -vframes 1 \\
                        -threads 1 -f image2 -q:v 2 "$thumb" >/dev/null 2>&1
                    ;;
                *)
                    thumb="$THUMB_DIR/$filename"
                    # "[0]" is the important part: without it an animated GIF
                    # decodes every frame. The jpeg:size hint lets libjpeg decode
                    # at reduced scale, and -thumbnail skips metadata handling.
                    [ -f "$thumb" ] || magick -define jpeg:size=x840 "$img[0]" \\
                        -thumbnail x420 -quality 70 "$thumb" 2>/dev/null
                    ;;
            esac
        }
        export -f gen_thumb
        export THUMB_DIR SRC_DIR

        # NUL-delimited rather than xargs -d, which is a GNU extension: this form
        # also survives filenames containing whitespace.
        comm -23 "$SRC_LIST" <(sed 's/^000_//' "$MANIFEST" | sort) \\
            | tr '\\n' '\\0' \\
            | xargs -0 -r -P "$(nproc 2>/dev/null || echo 4)" -I{} bash -c 'gen_thumb "$@"' _ {}

        # Rebuilt from disk rather than appended per job, which would race.
        build_manifest
'''

open(path, "w", encoding="utf-8").write(src[:start] + fast + src[end:])
PYEOF

    case $? in
        0) p_ok "thumbnail generation parallelised" ;;
        2) p_warn "unrecognised qs_manager.sh layout — patch skipped (file untouched)" ;;
        *) p_bad "failed to optimise thumbnails"; return 1 ;;
    esac
}

# ─── 4. Wire the palette hook and the autostart ──────────────────────────────

wire_matugen_hook() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/wpe/config"
    [ -f "$cfg" ] || return 0
    [ -f "$RELOAD_HOOK" ] || return 0

    if grep -q '^MATUGEN_HOOK=' "$cfg"; then
        sed -i "s|^MATUGEN_HOOK=.*|MATUGEN_HOOK=\"$RELOAD_HOOK\"|" "$cfg"
    else
        printf 'MATUGEN_HOOK="%s"\n' "$RELOAD_HOOK" >> "$cfg"
    fi
    sed -i 's|^SYNC_COLORS=.*|SYNC_COLORS=1|' "$cfg"
    p_ok "palette wired to matugen_reload.sh"
}

wire_autostart() {
    command -v jq >/dev/null 2>&1 || return 0
    if jq -e '.startup[]? | select(.command | test("wpe watch"))' "$SETTINGS" >/dev/null 2>&1; then
        p_info "autostart already configured"
        return 0
    fi
    # Staged beside the target, not in /tmp: same filesystem (so the replace is
    # atomic) and immune to a full or unwritable tmpfs, which is exactly how
    # this step failed during development.
    local tmp="$SETTINGS.wpe-tmp"
    if jq '.startup += [{"command":"wpe watch"}]' "$SETTINGS" > "$tmp" 2>/dev/null \
       && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$SETTINGS"
        p_ok "added 'wpe watch' to autostart"
    else
        rm -f "$tmp"
        p_warn "could not edit settings.json — add 'wpe watch' manually"
    fi
}

# ─── 5. Invalidate the thumbnail cache ───────────────────────────────────────
#
# The picker's grid is driven by the *thumbnail* folder, not by the wallpaper
# folder. Leaving stale thumbnails behind makes it list wallpapers that no
# longer exist at the expected path, so clicking one silently fails with
# "Path does not exist". This step is not optional.

invalidate_thumb_cache() {
    [ -d "$THUMB_CACHE" ] || return 0
    find "$THUMB_CACHE/thumbs" -maxdepth 1 -type f ! -name '.*' -delete 2>/dev/null
    find "$THUMB_CACHE/colors_markers" -maxdepth 1 -type f -delete 2>/dev/null
    rm -f "$THUMB_CACHE/colors.csv" "$THUMB_CACHE/colors.csv.bak" 2>/dev/null
    : > "$THUMB_CACHE/thumbs/.manifest" 2>/dev/null
    p_ok "thumbnail cache invalidated (rebuilds on next open)"
}

# ─────────────────────────────────────────────────────────────────────────────

plugin_install() {
    plugin_detect || { p_bad "imperative-dots not detected"; return 1; }

    install_previews   || return 1
    patch_picker       || return 1
    patch_thumbnails   || return 1
    wire_matugen_hook
    wire_autostart
    invalidate_thumb_cache

    printf '\n'
    p_info "Restart Quickshell to apply:"
    p_info "  pkill -x quickshell && hyprctl dispatch exec 'quickshell -p ~/.config/hypr/scripts/quickshell/Shell.qml'"
    return 0
}

plugin_status() {
    plugin_detect || { p_info "imperative-dots not detected"; return 1; }
    if grep -q "$MARKER" "$PICKER" 2>/dev/null; then
        p_ok "picker patched"
    else
        p_info "picker not patched"
    fi
    if grep -q "$MARKER" "$QS_MANAGER" 2>/dev/null; then
        p_ok "thumbnails optimised"
    else
        p_info "thumbnails not optimised"
    fi
    local n; n="$(find "$(wallpaper_dir)" -maxdepth 1 -name '0we_*' 2>/dev/null | wc -l)"
    p_info "$n previews exposed"
}

# Removes only what this plugin created, by name. Called by wpe-setup during
# rollback, before the archived dotfiles are restored. Deleting the whole
# wallpaper folder would destroy the user's own wallpapers.
plugin_cleanup() {
    local n=0 f
    if [ -f "$CREATED_MANIFEST" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && [ -f "$f" ] && rm -f -- "$f" && n=$((n + 1))
        done < "$CREATED_MANIFEST"
        rm -f "$CREATED_MANIFEST"
    fi

    # Thumbnails of removed previews would otherwise keep them listed in the
    # picker, pointing at files that no longer exist.
    invalidate_thumb_cache >/dev/null 2>&1
    p_ok "$n previews removed"
}

case "${1:-status}" in
    detect)  plugin_detect ;;
    targets) plugin_targets ;;
    install) plugin_install ;;
    cleanup) plugin_cleanup ;;
    status)  plugin_status ;;
    *)       printf 'usage: %s {detect|targets|install|cleanup|status}\n' "$(basename "$0")" >&2; exit 1 ;;
esac
