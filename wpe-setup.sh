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
die()  { printf '\n%sErreur:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$1" >&2; log FATAL "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  Detection — every path is probed, none is hardcoded
# ─────────────────────────────────────────────────────────────────────────────

# Steam can be a native package, a Flatpak or a Snap, and users relocate their
# libraries freely. Collect every plausible root, then let libraryfolders.vdf
# tell us about the extra drives.
detect_steam_roots() {
    local -a candidates=(
        "$HOME/.local/share/Steam"
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
        done < <(grep -oP '"path"\s*"\K[^"]+' "$vdf" 2>/dev/null)
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

# GNOME's Mutter does not implement wlr-layer-shell and there is no workaround
# an installer could apply, so it is called out explicitly rather than failing
# mysteriously later.
compositor_supported() {
    case "$1" in
        hyprland|sway|niri|wayfire|river|plasma|x11) return 0 ;;
        gnome) return 2 ;;
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
                wlr-randr 2>/dev/null | grep -oP '^\S+' | head -20
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

    head1 "Prérequis"

    local comp; comp="$(detect_compositor)"
    compositor_supported "$comp"
    case $? in
        0) ok "Compositeur : $comp (wlr-layer-shell disponible)" ;;
        2) bad "Compositeur : GNOME — n'implémente pas wlr-layer-shell."
           info "Le moteur ne peut pas dessiner de fond d'écran sous GNOME Wayland."
           info "Une session X11 ou un compositeur wlroots est nécessaire."
           CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1)) ;;
        *) warn "Compositeur non reconnu : $comp — le rendu n'est pas garanti"
           CHECK_WARNINGS=$((CHECK_WARNINGS + 1)) ;;
    esac

    local engine; engine="$(detect_engine)" \
        && ok "Moteur : $engine" \
        || { bad "linux-wallpaperengine introuvable"
             info "Arch/CachyOS : yay -S linux-wallpaperengine-git"
             info "Autres : https://github.com/Almamu/linux-wallpaperengine"
             CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1)); }

    local roots; roots="$(detect_steam_roots)"
    if [ -n "$roots" ]; then
        ok "Steam : $(echo "$roots" | wc -l) bibliothèque(s)"
        echo "$roots" | while IFS= read -r r; do info "$r"; done
    else
        bad "Aucune bibliothèque Steam trouvée"
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    local assets; assets="$(detect_assets_dir)" \
        && ok "Assets Wallpaper Engine : $assets" \
        || { bad "Wallpaper Engine n'est pas installé via Steam"
             info "Les wallpapers 'scene' ont besoin de ses shaders et matériaux."
             CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1)); }

    local n; n="$(count_wallpapers)"
    if [ "$n" -gt 0 ]; then
        ok "Wallpapers Workshop : $n"
    else
        bad "Aucun wallpaper téléchargé"
        info "Abonne-toi à des wallpapers dans le Workshop Steam, puis relance."
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    local audio; audio="$(detect_audio_server)"
    if [ "$audio" = "pipewire" ]; then
        ok "Audio : PipeWire — --noautomute sera appliqué (obligatoire)"
    else
        ok "Audio : $audio"
    fi

    local dep missing=()
    for dep in jq find awk; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
    if [ ${#missing[@]} -eq 0 ]; then
        ok "Dépendances : jq, find, awk"
    else
        bad "Manquant : ${missing[*]}"
        CHECK_BLOCKERS=$((CHECK_BLOCKERS + 1))
    fi

    if command -v matugen >/dev/null 2>&1; then
        ok "matugen présent — synchronisation des couleurs activable"
    else
        info "matugen absent — la synchro des couleurs sera désactivée (optionnel)"
    fi

    local plugins; plugins="$(available_plugins)"
    if [ -n "$plugins" ]; then
        local p
        while IFS= read -r p; do
            ok "Intégration disponible : $(basename "$p" .sh)"
        done <<< "$plugins"
    fi

    head1 "Verdict"
    if [ "$CHECK_BLOCKERS" -gt 0 ]; then
        bad "$CHECK_BLOCKERS prérequis critique(s) manquant(s)"
        return 1
    fi
    [ "$CHECK_WARNINGS" -gt 0 ] && warn "$CHECK_WARNINGS avertissement(s)"
    ok "Tout est prêt"
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

    if [ ${#existing[@]} -gt 0 ]; then
        tar czf "$archive" -C / "${existing[@]#/}" 2>/dev/null \
            || tar czf "$archive" "${existing[@]}" 2>/dev/null \
            || { rm -f "$archive"; return 1; }
    else
        # Nothing pre-existing: an empty marker still lets rollback clean up.
        tar czf "$archive" -T /dev/null 2>/dev/null
    fi

    echo "$archive"
}

do_rollback() {
    head1 "Restauration"

    [ -d "$BACKUP_DIR" ] || die "Aucune sauvegarde trouvée dans $BACKUP_DIR"

    local archive
    archive="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' | sort | tail -1)"
    [ -n "$archive" ] || die "Aucune sauvegarde trouvée"

    local listing="${archive%.tar.gz}.files"

    info "Sauvegarde : $(basename "$archive")"
    printf '\n  Restaurer cet état ? [o/N] '
    local reply; read -r reply
    case "$reply" in [oO]|[yY]) ;; *) info "Annulé"; return 0 ;; esac

    # Remove what we created, then restore what existed.
    if [ -f "$listing" ]; then
        local t
        while IFS= read -r t; do
            [ -n "$t" ] && rm -rf "$t"
        done < "$listing"
    fi

    tar xzf "$archive" -C / 2>/dev/null || tar xzf "$archive" -C "$HOME" 2>/dev/null || true

    rm -f "$STATE_FILE"
    ok "État restauré"
    info "Le moteur et les paquets système n'ont pas été touchés."
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  Install
# ─────────────────────────────────────────────────────────────────────────────

write_runtime() {
    local workshop assets outputs
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

    cp "$(dirname "${BASH_SOURCE[0]}")/lib/wpe" "$BIN_DIR/wpe" 2>/dev/null \
        || return 1
    chmod +x "$BIN_DIR/wpe"
    return 0
}

do_install() {
    head1 "Vérification avant installation"
    if ! run_check; then
        printf '\n%s  Des prérequis critiques manquent.%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
        printf '  Continuer est %sfortement déconseillé%s : la configuration produite\n' "$C_BOLD" "$C_RESET"
        printf '  ne fonctionnera pas, et tu risques de perturber ta session.\n'
        printf '\n  Continuer quand même ? [o/N] '
        local reply; read -r reply
        case "$reply" in [oO]|[yY]) warn "Poursuite forcée par l'utilisateur" ;; *) info "Annulé — rien n'a été modifié"; return 1 ;; esac
    fi

    head1 "Sauvegarde"
    local archive
    archive="$(create_backup)" || die "La sauvegarde a échoué — rien n'a été modifié"
    ok "Sauvegarde créée : $archive"
    info "« wpe-setup rollback » restaurera cet état exact."

    head1 "Installation"
    write_runtime || die "Installation impossible — utilise « wpe-setup rollback »"
    ok "Commande « wpe » installée dans $BIN_DIR"
    ok "Configuration écrite dans $CONFIG_DIR/config"

    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
INSTALLED_AT="$(date -Is)"
VERSION="$WPE_VERSION"
BACKUP="$archive"
COMPOSITOR="$(detect_compositor)"
EOF

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR n'est pas dans ton PATH"
           info "Ajoute : export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac

    local plugins; plugins="$(available_plugins)"
    if [ -n "$plugins" ]; then
        head1 "Intégrations détectées"
        local p
        while IFS= read -r p; do
            info "$(basename "$p" .sh)"
        done <<< "$plugins"
        printf '\n  Les activer ? Elles intègrent tes wallpapers directement\n'
        printf '  dans ton environnement de bureau. [O/n] '
        local reply; read -r reply
        case "$reply" in
            [nN]) info "Intégrations ignorées" ;;
            *) while IFS= read -r p; do
                   head1 "Intégration : $(basename "$p" .sh)"
                   "$p" install || warn "l'intégration a échoué — « wpe-setup rollback » annule tout"
               done <<< "$plugins" ;;
        esac
    fi

    head1 "Terminé"
    info "wpe list          les wallpapers disponibles"
    info "wpe random        en appliquer un au hasard"
    info "wpe set <id>      en appliquer un précis"
    info "wpe watch         garder le moteur vivant (à mettre dans ton autostart)"
    return 0
}

do_status() {
    head1 "État"
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        ok "Installé le ${INSTALLED_AT:-?} (version ${VERSION:-?})"
        info "Sauvegarde : ${BACKUP:-aucune}"
    else
        info "wpe-setup n'est pas installé sur cette machine"
    fi
    info "Compositeur : $(detect_compositor)"
    info "Wallpapers  : $(count_wallpapers)"
    pgrep -x linux-wallpaper >/dev/null 2>&1 && ok "Moteur en cours d'exécution" || info "Moteur arrêté"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Menu
# ─────────────────────────────────────────────────────────────────────────────

banner() {
    printf '\n%s  wpe-setup %s%s — Wallpaper Engine sur Linux, en une commande\n' \
        "$C_BOLD$C_BLUE" "$WPE_VERSION" "$C_RESET"
}

menu() {
    banner
    printf '\n  %s1%s  Vérifier les prérequis %s(ne modifie rien)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s2%s  Installer et configurer\n' "$C_BOLD" "$C_RESET"
    printf '  %s3%s  Revenir en arrière %s(restaurer la sauvegarde)%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '  %s4%s  État actuel\n' "$C_BOLD" "$C_RESET"
    printf '  %s5%s  Quitter\n' "$C_BOLD" "$C_RESET"
    printf '\n  Ton choix [1-5] : '

    local choice; read -r choice
    case "$choice" in
        1) run_check || true ;;
        2) do_install || true ;;
        3) do_rollback || true ;;
        4) do_status ;;
        5) return 0 ;;
        *) warn "Choix invalide" ;;
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
