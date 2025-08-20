#!/usr/bin/env bash

set -euo pipefail

# SONiC offline image customization script (overlay-based)
# Targeted for SONiC 202411 on Seastone DX010 (x86_64-cel_seastone-r0)
# Prepares an overlay mounted at /newroot and applies changes there.

# Configurable thresholds
RECENT_THRESHOLD_SECONDS=$((4 * 3600))
WARN_THRESHOLD_SECONDS=$((72 * 3600))

FLASH_MOUNT="/media/flashdrive"

SCRIPT_VERSION="2025.08.20-4"
DRY_RUN=0
NO_HANDHOLDING=0
DISABLE_BREW=0
DISABLE_FANCONTROL=0
IMAGE_DIR=""
RW_NAME=""
LOWER_MODE="auto"
ACTIVATE=0
RETAIN=2

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  -n, --dry-run                    Print planned actions without modifying the filesystem
  -q, --no-handholding, --no-hand-holding
                                   Skip non-essential confirmations; proceed after warnings
  --no-brew                        Skip installing the Homebrew first-boot service
  --no-fancontrol                  Skip installing fancontrol settings and services
  --image-dir DIR                  Target image directory (default: newest /host/image-*)
  --rw-name NAME                   Name for new overlay upper/work (default: timestamp)
  --lower MODE                     Lower selection: auto|fs|dir (default: auto)
  --activate                       After customizing, live-activate overlay (rename rw/work)
  --retain N                       Retain N old overlays when activating (default: 2)
  -h, --help                       Show this help
USAGE
}

required_binaries=(
    sonic-installer
    stat
    awk
    sed
    date
    rsync
    blkid
    findmnt
    mount
    mountpoint
)

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "${LOGFILE:-/dev/stderr}" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

need_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "This script must be run as root."
    fi
}

check_binaries() {
    local missing=0
    for bin in "${required_binaries[@]}"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log "WARN: Missing required binary '$bin'. Some steps may fail."
            missing=1
        fi
    done
    return 0
}

detect_platform() {
    local platform
    if command -v sonic-cfggen >/dev/null 2>&1; then
        if platform=$(sonic-cfggen -H -v DEVICE_METADATA.localhost.platform 2>/dev/null || true); then
            if [[ -n "$platform" ]]; then
                echo "$platform"
                return 0
            fi
        fi
    fi
    # Fallback to user-provided known platform
    echo "x86_64-cel_seastone-r0"
}

detect_newest_offline_image_dir() {
    # Heuristic: pick the most recently modified /host/image-* directory
    local newest mtime path
    newest=""
    mtime=0
    for path in /host/image-*; do
        [[ -d "$path" ]] || continue
        local t
        if [[ -d "$path/rw" ]]; then
            t=$(stat -c %Y "$path/rw" 2>/dev/null || echo 0)
        elif [[ -d "$path/fsroot" ]]; then
            t=$(stat -c %Y "$path/fsroot" 2>/dev/null || echo 0)
        else
            t=$(stat -c %Y "$path" 2>/dev/null || echo 0)
        fi
        if [[ "$t" -gt "$mtime" ]]; then
            mtime=$t
            newest=$path
        fi
    done
    [[ -n "$newest" ]] || return 1
    echo "$newest"
}

image_dir_to_name() {
    local dir="$1"
    basename "$dir" | sed 's/^image-//'
}

verify_recent_install() {
    local dir="$1"
    local now ts age
    # Prefer rw overlay timestamp, then fsroot, then directory
    if [[ -d "$dir/rw" ]]; then
        ts=$(stat -c %Y "$dir/rw")
    elif [[ -d "$dir/fsroot" ]]; then
        ts=$(stat -c %Y "$dir/fsroot")
    else
        ts=$(stat -c %Y "$dir")
    fi
    now=$(date +%s)
    age=$((now - ts))
    if [[ $age -le $RECENT_THRESHOLD_SECONDS ]]; then
        log "New image directory '$dir' appears recent (<= 4 hours). Proceeding."
        return 0
    fi
    if [[ $age -le $WARN_THRESHOLD_SECONDS ]]; then
        local hrs=$((age / 3600))
        log "WARN: '$dir' modified ${hrs} hours ago."
        log "      This script is intended to customize a NEWLY INSTALLED image."
        log "      If you meant to customize a new deployment, first run: 'sonic-installer install <image_or_url>' and then re-run this script."
        if [[ "$NO_HANDHOLDING" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
            return 0
        fi
        read -r -p "Continue customizing this not-so-recent image? [y/N]: " ans || true
        case "${ans,,}" in
            y|yes) ;;
            *) die "Aborted by user due to image age warning." ;;
        esac
        return 0
    fi
    log "WARN: '$dir' modified more than 72 hours ago. This script is intended to customize a NEWLY INSTALLED image."
    log "      If you meant to customize a new deployment, first run: 'sonic-installer install <image_or_url>' and then re-run this script."
    if [[ "$NO_HANDHOLDING" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    echo -n "Type 'proceed' to continue anyway: "
    read -r confirm || true
    if [[ "$confirm" != "proceed" ]]; then
        die "Aborted by user due to very stale image warning."
    fi
}

ensure_dir() {
    local d="$1"
    if [[ ! -d "$d" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: mkdir -p $d"
        else
            mkdir -p "$d"
        fi
    fi
}

# ... existing code ...

prepare_overlay_or_die() {
    local image_dir="$1" rw_name="$2" lower_mode="$3"
    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    local overlay_tool="$script_dir/sonic-overlay.sh"
    [[ -x "$overlay_tool" ]] || die "Overlay tool not found or not executable: $overlay_tool"
    local cmd=("$overlay_tool" prepare --image-dir "$image_dir" --lower "$lower_mode" --rw-name "$rw_name" --mount)
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: ${cmd[*]}"
    else
        "${cmd[@]}"
    fi
    if ! mountpoint -q /newroot; then
        die "/newroot is not mounted; overlay prepare failed"
    fi
}

activate_overlay_if_requested() {
    local image_dir="$1" rw_name="$2" retain="$3"
    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    local overlay_tool="$script_dir/sonic-overlay.sh"
    [[ -x "$overlay_tool" ]] || die "Overlay tool not found or not executable: $overlay_tool"
    if [[ "$ACTIVATE" -eq 1 ]]; then
        local cmd=("$overlay_tool" activate --image-dir "$image_dir" --rw-name "$rw_name" --retain "$retain")
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: ${cmd[*]}"
        else
            "${cmd[@]}"
        fi
    else
        log "To activate overlay for next boot: $overlay_tool activate --image-dir '$image_dir' --rw-name '$rw_name' --retain $retain"
    fi
}

main() {
    need_root
    check_binaries || true

    # Arg parsing
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=1
                ;;
            -q|--no-handholding|--no-hand-holding|--quiet)
                NO_HANDHOLDING=1
                ;;
            --no-brew)
                DISABLE_BREW=1
                ;;
            --no-fancontrol)
                DISABLE_FANCONTROL=1
                ;;
            --image-dir)
                IMAGE_DIR=${2:-}
                shift
                ;;
            --rw-name)
                RW_NAME=${2:-}
                shift
                ;;
            --lower)
                LOWER_MODE=${2:-auto}
                shift
                ;;
            --activate)
                ACTIVATE=1
                ;;
            --retain)
                RETAIN=${2:-2}
                shift
                ;;
            -h|--help)
                usage; exit 0
                ;;
            *)
                log "WARN: Unknown argument: $1"
                ;;
        esac
        shift
    done

    log "Starting sonic-offline-customize version $SCRIPT_VERSION (dry-run=$DRY_RUN, no-handholding=$NO_HANDHOLDING, no-brew=$DISABLE_BREW, no-fancontrol=$DISABLE_FANCONTROL)"

    # Optional: warn if running config differs from saved config
    if command -v show >/dev/null 2>&1 && command -v sonic-cfggen >/dev/null 2>&1; then
        # Dump current running config in JSON form and compare against saved config_db.json ignoring whitespace
        # Note: list order differences may appear; this is an advisory warning only.
        if running=$(show runningconfiguration all 2>/dev/null | sed -n '/^{/,$p'); then
            tmp_run=$(mktemp)
            tmp_save=$(mktemp)
            echo "$running" >"$tmp_run"
            if [[ -f /etc/sonic/config_db.json ]]; then
                # Normalize both sides minimally (strip spaces)
                sed 's/[[:space:]]//g' /etc/sonic/config_db.json >"$tmp_save"
                sed -i 's/[[:space:]]//g' "$tmp_run"
                if ! diff -q "$tmp_run" "$tmp_save" >/dev/null 2>&1; then
                    log "WARN: Running config differs from saved config_db.json. Differences may be cosmetic (list order)."
                fi
            fi
            rm -f "$tmp_run" "$tmp_save" || true
        fi
    fi

    local target_dir
    if [[ -z "$IMAGE_DIR" ]]; then
        target_dir=$(detect_newest_offline_image_dir) || die "Could not find any /host/image-* directories"
    else
        target_dir="$IMAGE_DIR"
    fi
    [[ -d "$target_dir" ]] || die "Image directory not found: $target_dir"
    verify_recent_install "$target_dir"

    # Prepare overlay at /newroot (uniform customization path)
    if [[ -z "$RW_NAME" ]]; then RW_NAME=$(date +%Y%m%d-%H%M%S); fi
    prepare_overlay_or_die "$target_dir" "$RW_NAME" "$LOWER_MODE"
    local offline_root="/newroot"

    local already
    already=$(already_customized_exit_if_true "$offline_root")
    if [[ "$already" == "ALREADY" ]]; then
        echo "Customization already applied to $offline_root. Exiting."
        exit 0
    fi

    write_marker_and_copy_self "$offline_root"

    local platform
    platform=$(detect_platform)
    log "Detected platform: $platform"

    copy_config_db "$offline_root"
    copy_homes "$offline_root"
    copy_ssh_settings_and_keys "$offline_root"
    copy_admin_password_hash "$offline_root"
    update_fstab_for_flashdrive "$offline_root"
    if [[ "$DISABLE_BREW" -eq 0 ]]; then
        install_brew_first_boot_service "$offline_root"
    else
        log "Skipping Homebrew bootstrap (flagged --no-brew)"
    fi
    if [[ "$DISABLE_FANCONTROL" -eq 0 ]]; then
        install_fancontrol_assets "$offline_root" "$platform"
    else
        log "Skipping fancontrol customization (flagged --no-fancontrol)"
    fi

    local image_name
    image_name=$(image_dir_to_name "$target_dir")
    log "Target image name: $image_name"

    # Optionally live-activate overlay now
    activate_overlay_if_requested "$target_dir" "$RW_NAME" "$RETAIN"

    set_next_boot_prompt "$image_name"
    maybe_reboot_prompt

    # Mark completion for idempotency
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: would mark CUSTOMIZATION_COMPLETED in $LOGFILE"
    else
        if [[ -n "${LOGFILE:-}" ]]; then
            echo "CUSTOMIZATION_COMPLETED $(date -Is) version $SCRIPT_VERSION" >>"$LOGFILE" || true
        else
            ensure_dir "$offline_root/var/log" && echo "CUSTOMIZATION_COMPLETED $(date -Is) version $SCRIPT_VERSION" >>"$offline_root/var/log/sonic-offline-customize.log" || true
        fi
    fi
    log "Done."
}

main "$@"