#!/usr/bin/env bash

set -euo pipefail

# SONiC deployment orchestrator
# High-level flows:
# - backup: create a backup tarball from the running system
# - restore: prepare overlay on target image and restore backup into /newroot
# - install: sonic-installer install -f <bin>; customize against overlay; if same-image, activate overlay

SCRIPT_VERSION="2025.08.20-1"

usage() {
    cat <<USAGE
Usage:
  $0 backup   --output <path.tgz>
  $0 restore  [--image-dir DIR] [--rw-name NAME] [--lower auto|fs|dir] --input <path.tgz>
  $0 install  --bin <sonic-image.bin> [--rw-name NAME] [--lower auto|fs|dir] [--no-brew] [--no-fancontrol] [--no-handholding] [--dry-run]

Notes:
  - restore: prepares overlay at /newroot before applying backup to /newroot
  - install: runs sonic-installer; if it reports "already installed" then treat as same-image and activate overlay; otherwise customize and set next boot
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_root() { [[ ${EUID} -eq 0 ]] || die "Must run as root"; }

detect_newest_image() {
    local newest="" mtime=0 p t
    for p in /host/image-*; do
        [[ -d "$p" ]] || continue
        if [[ -d "$p/rw" ]]; then t=$(stat -c %Y "$p/rw" 2>/dev/null || echo 0); 
        elif [[ -d "$p/fsroot" ]]; then t=$(stat -c %Y "$p/fsroot" 2>/dev/null || echo 0); 
        else t=$(stat -c %Y "$p" 2>/dev/null || echo 0); fi
        if [[ $t -gt $mtime ]]; then mtime=$t; newest=$p; fi
    done
    [[ -n "$newest" ]] || return 1
    echo "$newest"
}

run_backup() {
    local out="$1"
    [[ -n "$out" ]] || die "--output is required"
    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    "$script_dir/sonic-backup.sh" backup --output "$out"
}

run_restore() {
    local image_dir="$1" rw_name="$2" lower="$3" input="$4"
    [[ -r "$input" ]] || die "--input not readable"
    [[ -n "$image_dir" ]] || image_dir=$(detect_newest_image) || die "No image dir found"
    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    "$script_dir/sonic-overlay.sh" prepare --image-dir "$image_dir" --lower "${lower:-auto}" ${rw_name:+--rw-name "$rw_name"} --mount
    "$script_dir/sonic-backup.sh" restore --input "$input" --target-root /newroot
    log "Restore complete into /newroot. You may now customize or activate overlay."
}

run_install() {
    local bin="$1" rw_name="$2" lower="$3" dry_run="$4" no_hand="$5" no_brew="$6" no_fan="$7"
    [[ -r "$bin" ]] || die "--bin not readable"
    local output
    if [[ "$dry_run" == "1" ]]; then
        log "DRY-RUN: sonic-installer install -y -f $bin"
        output=""
    else
        output=$(sonic-installer install -y -f "$bin" 2>&1 | tee /tmp/sonic_install.log || true)
    fi

    local image_dir
    if echo "$output" | grep -qi "already installed"; then
        log "Installer reports image already installed; treating as same-image"
        image_dir=$(detect_newest_image) || die "Unable to detect image dir"
        # Customize against overlay and activate for same-image
        local args=(--image-dir "$image_dir" --lower "${lower:-auto}" )
        [[ -n "$rw_name" ]] && args+=(--rw-name "$rw_name")
        [[ "$no_hand" == "1" ]] && args+=(--no-handholding)
        [[ "$no_brew" == "1" ]] && args+=(--no-brew)
        [[ "$no_fan" == "1" ]] && args+=(--no-fancontrol)
        args+=(--activate)
        [[ "$dry_run" == "1" ]] && args+=(--dry-run)
        local script_dir="$(cd "$(dirname "$0")" && pwd)"
        "$script_dir/sonic-offline-customize.sh" "${args[@]}"
    else
        # New image case: customize against new image; no activation needed
        image_dir=$(detect_newest_image) || die "Unable to detect newly installed image dir"
        local args=(--image-dir "$image_dir" --lower "${lower:-auto}")
        [[ -n "$rw_name" ]] && args+=(--rw-name "$rw_name")
        [[ "$no_hand" == "1" ]] && args+=(--no-handholding)
        [[ "$no_brew" == "1" ]] && args+=(--no-brew)
        [[ "$no_fan" == "1" ]] && args+=(--no-fancontrol)
        [[ "$dry_run" == "1" ]] && args+=(--dry-run)
        local script_dir="$(cd "$(dirname "$0")" && pwd)"
        "$script_dir/sonic-offline-customize.sh" "${args[@]}"
    fi
}

main() {
    need_root
    local cmd=${1:-}; shift || true
    case "$cmd" in
        backup)
            local out=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --output) out=${2:-}; shift ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            run_backup "$out"
            ;;
        restore)
            local image_dir="" rw_name="" lower="auto" input=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --image-dir) image_dir=${2:-}; shift ;;
                    --rw-name) rw_name=${2:-}; shift ;;
                    --lower) lower=${2:-}; shift ;;
                    --input) input=${2:-}; shift ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            [[ -n "$input" ]] || die "--input is required"
            run_restore "$image_dir" "$rw_name" "$lower" "$input"
            ;;
        install)
            local bin="" rw_name="" lower="auto" dry_run=0 no_hand=0 no_brew=0 no_fan=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --bin) bin=${2:-}; shift ;;
                    --rw-name) rw_name=${2:-}; shift ;;
                    --lower) lower=${2:-}; shift ;;
                    --dry-run|-n) dry_run=1 ;;
                    --no-handholding|-q|--no-hand-holding) no_hand=1 ;;
                    --no-brew) no_brew=1 ;;
                    --no-fancontrol) no_fan=1 ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            [[ -n "$bin" ]] || die "--bin is required"
            run_install "$bin" "$rw_name" "$lower" "$dry_run" "$no_hand" "$no_brew" "$no_fan"
            ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

