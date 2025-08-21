#!/usr/bin/env bash

set -euo pipefail

# SONiC overlay manager: prepare /newroot against chosen lower, apply changes, activate

# source common helpers (required)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sonic-common.sh"

usage() {
    cat <<USAGE
Usage:
  $0 prepare --image-dir </host/image-*> [--lower auto|fs|dir] [--rw-name <name>] [--mount]
  $0 unmount
  $0 activate --image-dir </host/image-*> --rw-name <name> [--retain 2]

Notes:
  - prepare: creates rw-next-<name> (upper/work) under image-dir and optionally mounts overlay at /newroot
  - activate: live-rename rw/work to rw-old-<ts>, and rw-next-<name> to rw; retains N old sets
USAGE
}

resolve_lower() {
    local image_dir="$1" mode="$2"
    [[ -d "$image_dir" ]] || die "image-dir not found: $image_dir"
    if [[ "$mode" == "auto" ]]; then
        if [[ -f "$image_dir/fs.squashfs" ]]; then echo "$image_dir/fs.squashfs"; return 0; fi
        if [[ -d "$image_dir/fsroot" ]]; then echo "$image_dir/fsroot"; return 0; fi
        die "No fs.squashfs or fsroot under $image_dir"
    elif [[ "$mode" == "fs" ]]; then
        [[ -f "$image_dir/fs.squashfs" ]] || die "fs.squashfs not found"
        echo "$image_dir/fs.squashfs"
    elif [[ "$mode" == "dir" ]]; then
        [[ -d "$image_dir/fsroot" ]] || die "fsroot dir not found"
        echo "$image_dir/fsroot"
    else
        die "Unknown lower mode: $mode"
    fi
}

prepare() {
    local image_dir="$1" lower_mode="$2" rw_name="$3" do_mount="$4"
    local lower
    lower=$(resolve_lower "$image_dir" "$lower_mode")

    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    [[ -n "$rw_name" ]] || rw_name="$stamp"
    local rw_next="$image_dir/rw-next-$rw_name"
    local work_next="$image_dir/work-next-$rw_name"
    dry mkdir -p "$rw_next/upper" "$work_next"

    if [[ "$do_mount" == "1" ]]; then
        dry mkdir -p /mnt/newroot.lower /newroot
        local lower_dir="$lower"
        if [[ -f "$lower" ]]; then
            # mount squashfs
            if ! mountpoint -q /mnt/newroot.lower; then dry mount -t squashfs -o ro "$lower" /mnt/newroot.lower; fi
            lower_dir="/mnt/newroot.lower"
        fi
        if ! mountpoint -q /newroot; then dry mount -t overlay overlay -o lowerdir="$lower_dir",upperdir="$rw_next/upper",workdir="$work_next" /newroot; fi
        log "Mounted overlay at /newroot (lower=$lower_dir upper=$rw_next/upper work=$work_next)"
    else
        log "Prepared upper/work: $rw_next/upper and $work_next (not mounted)"
    fi
}

unmount_newroot() {
    if mountpoint -q /newroot; then
        dry umount /newroot || die "Failed to unmount /newroot"
    fi
    if mountpoint -q /mnt/newroot.lower; then
        dry umount /mnt/newroot.lower || true
    fi
}

activate() {
    local image_dir="$1" rw_name="$2" retain="$3"
    [[ -d "$image_dir" ]] || die "image-dir not found"
    local rw_cur="$image_dir/rw"
    local work_cur="$image_dir/work"
    local rw_next="$image_dir/rw-next-$rw_name"
    local work_next="$image_dir/work-next-$rw_name"

    [[ -d "$rw_next/upper" ]] || die "Missing $rw_next/upper"
    [[ -d "$work_next" ]] || die "Missing $work_next"

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    if [[ -d "$rw_cur" ]]; then dry mv "$rw_cur" "$image_dir/rw-old-$ts"; fi
    if [[ -d "$work_cur" ]]; then dry mv "$work_cur" "$image_dir/work-old-$ts"; fi
    dry mv "$rw_next" "$rw_cur"
    dry mv "$work_next" "$work_cur"
    log "Activated new overlay (rw/work swapped). Previous saved with -old-$ts"

    # Retention
    retain=${retain:-2}
    local olds
    mapfile -t olds < <(ls -1dt "$image_dir"/rw-old-* 2>/dev/null | tail -n +$((retain+1)) || true)
    for d in "${olds[@]:-}"; do [[ -n "$d" ]] && dry rm -rf "$d"; done
    mapfile -t olds < <(ls -1dt "$image_dir"/work-old-* 2>/dev/null | tail -n +$((retain+1)) || true)
    for d in "${olds[@]:-}"; do [[ -n "$d" ]] && dry rm -rf "$d"; done
}

main() {
    need_root
    local cmd=${1:-}; shift || true
    case "$cmd" in
        prepare)
            local image_dir="" lower="auto" rw_name="" do_mount=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --image-dir) image_dir=${2:-}; shift ;;
                    --lower) lower=${2:-}; shift ;;
                    --rw-name) rw_name=${2:-}; shift ;;
                    --mount) do_mount=1 ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            [[ -n "$image_dir" ]] || die "--image-dir is required"
            prepare "$image_dir" "$lower" "$rw_name" "$do_mount"
            ;;
        unmount)
            unmount_newroot
            ;;
        activate)
            local image_dir="" rw_name="" retain=2
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --image-dir) image_dir=${2:-}; shift ;;
                    --rw-name) rw_name=${2:-}; shift ;;
                    --retain) retain=${2:-}; shift ;;
                    -h|--help) usage; exit 0 ;;
                    *) log "WARN: unknown arg $1" ;;
                esac; shift
            done
            [[ -n "$image_dir" && -n "$rw_name" ]] || die "--image-dir and --rw-name are required"
            activate "$image_dir" "$rw_name" "$retain"
            ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"

