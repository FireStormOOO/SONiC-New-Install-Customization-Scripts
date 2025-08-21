#!/usr/bin/env bash

set -euo pipefail

# SONiC deployment orchestrator
# High-level flows:
# - backup: create a backup tarball from the running system
# - restore: prepare overlay on target image and restore backup into /newroot
# - install: sonic-installer install -f <bin>; customize against overlay; if same-image, activate overlay

SCRIPT_VERSION="2025.08.20-3"

usage() {
    cat <<USAGE
Usage:
  $0 backup      --output <path.tgz> [--source-root /]
  $0 restore     [--image-dir DIR] [--rw-name NAME] [--lower auto|fs|dir] --input <path.tgz> [--target-root /newroot]
  $0 install     --bin <sonic-image.bin> [--rw-name NAME] [--lower auto|fs|dir] [--no-brew] [--no-fancontrol] [--no-handholding|--quiet] [--dry-run]
  $0 reinstall   [--rw-name NAME] [--lower auto|fs|dir] [--no-brew] [--no-fancontrol] [--no-handholding|--quiet] [--dry-run]

Notes:
  - restore: prepares overlay at /newroot before applying backup to /newroot
  - install: runs sonic-installer; if it reports "already installed" then treat as same-image and activate overlay; otherwise customize and set next boot
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_root() { [[ ${EUID} -eq 0 ]] || die "Must run as root"; }

# source common helpers (required)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sonic-common.sh"

# source common helpers
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/sonic-common.sh" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/sonic-common.sh"
fi

# prefer library's detect_newest_image_dir
detect_newest_image() { detect_newest_image_dir; }

# use shared helper if available
declare -F detect_current_image_dir >/dev/null 2>&1 || detect_current_image_dir() { detect_newest_image; }

run_backup() {
    local out="$1" source_root="$2"
    [[ -n "$out" ]] || die "--output is required"
    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [[ -n "$source_root" ]]; then
        "$script_dir/sonic-backup.sh" backup --output "$out" --source-root "$source_root"
    else
        "$script_dir/sonic-backup.sh" backup --output "$out"
    fi
}

run_restore() {
    local image_dir="$1" rw_name="$2" lower="$3" input="$4" target_root="$5"
    [[ -r "$input" ]] || die "--input not readable"
    [[ -n "$image_dir" ]] || image_dir=$(detect_newest_image) || die "No image dir found"
    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    "$script_dir/sonic-overlay.sh" prepare --image-dir "$image_dir" --lower "${lower:-auto}" ${rw_name:+--rw-name "$rw_name"} --mount
    [[ -n "$target_root" ]] || target_root="/newroot"
    if [[ "$target_root" == "/newroot" && ! $(mountpoint -q /newroot; echo $?) -eq 0 ]]; then
        die "Target root '/newroot' is not mounted. Prepare an overlay first: sonic-overlay.sh prepare --image-dir $image_dir --lower auto --rw-name <name> --mount"
    fi
    "$script_dir/sonic-backup.sh" restore --input "$input" --target-root "$target_root"
    log "Restore complete into $target_root. You may now customize or activate overlay."
}

run_install() {
    local bin="$1" rw_name="$2" lower="$3" dry_run="$4" no_hand="$5" no_brew="$6" no_fan="$7"
    [[ -r "$bin" ]] || die "--bin not readable"
    local output
    if [[ "$dry_run" == "1" ]]; then
        log "DRY-RUN: sonic-installer install -y $bin"
        output=""
    else
        output=$(sonic-installer install -y "$bin" 2>&1 | tee /tmp/sonic_install.log || true)
    fi

    local image_dir
    if echo "$output" | grep -qi "already installed"; then
        log "Installer reports image already installed; treating as same-image"
        image_dir=$(detect_current_image_dir) || die "Unable to detect image dir"
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
            local out="" source_root=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --output) out=${2:-}; shift ;;
                    --source-root) source_root=${2:-}; shift ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            run_backup "$out" "$source_root"
            ;;
        restore)
            local image_dir="" rw_name="" lower="auto" input="" target_root=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --image-dir) image_dir=${2:-}; shift ;;
                    --rw-name) rw_name=${2:-}; shift ;;
                    --lower) lower=${2:-}; shift ;;
                    --input) input=${2:-}; shift ;;
                    --target-root) target_root=${2:-}; shift ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            [[ -n "$input" ]] || die "--input is required"
            run_restore "$image_dir" "$rw_name" "$lower" "$input" "$target_root"
            ;;
        reinstall)
            local rw_name="" lower="auto" dry_run=0 no_hand=0 no_brew=0 no_fan=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --rw-name) rw_name=${2:-}; shift ;;
                    --lower) lower=${2:-}; shift ;;
                    --dry-run|-n) dry_run=1 ;;
                    --no-handholding|-q|--no-hand-holding|--quiet) no_hand=1 ;;
                    --no-brew) no_brew=1 ;;
                    --no-fancontrol) no_fan=1 ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            local image_dir
            image_dir=$(detect_current_image_dir) || die "Unable to detect current image dir"
            local args=(--image-dir "$image_dir" --lower "$lower")
            [[ -n "$rw_name" ]] && args+=(--rw-name "$rw_name")
            [[ "$no_hand" == "1" ]] && args+=(--no-handholding)
            [[ "$no_brew" == "1" ]] && args+=(--no-brew)
            [[ "$no_fan" == "1" ]] && args+=(--no-fancontrol)
            args+=(--activate)
            [[ "$dry_run" == "1" ]] && args+=(--dry-run)
            local script_dir="$(cd "$(dirname "$0")" && pwd)"
            "$script_dir/sonic-offline-customize.sh" "${args[@]}"
            ;;
        install)
            local bin="" rw_name="" lower="auto" dry_run=0 no_hand=0 no_brew=0 no_fan=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --bin) bin=${2:-}; shift ;;
                    --rw-name) rw_name=${2:-}; shift ;;
                    --lower) lower=${2:-}; shift ;;
                    --dry-run|-n) dry_run=1 ;;
                    --no-handholding|-q|--no-hand-holding|--quiet) no_hand=1 ;;
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

