#!/usr/bin/env bash

set -euo pipefail

# SONiC offline image customization script (overlay-based)
# Targeted for SONiC 202411 on Seastone DX010 (x86_64-cel_seastone-r0)
# Prepares an overlay mounted at /newroot and applies changes there.

# Configurable thresholds
RECENT_THRESHOLD_SECONDS=$((4 * 3600))
WARN_THRESHOLD_SECONDS=$((72 * 3600))

FLASH_MOUNT="/media/flashdrive"

SCRIPT_VERSION="2025.08.20-5"
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

# source common helpers early (still honor local overrides)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/sonic-common.sh" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/sonic-common.sh"
fi

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
    local platform=""
    if command -v sonic-cfggen >/dev/null 2>&1; then
        platform=$(sonic-cfggen -H -v DEVICE_METADATA.localhost.platform 2>/dev/null || true)
    fi
    echo "$platform"
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

enable_service_in_offline() {
    local offline_root="$1"
    local unit_name="$2"
    ensure_dir "$offline_root/etc/systemd/system/multi-user.target.wants"
    if [[ -f "$offline_root/etc/systemd/system/$unit_name" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: ln -sf ../$unit_name $offline_root/etc/systemd/system/multi-user.target.wants/$unit_name"
        else
            ln -sf "../$unit_name" "$offline_root/etc/systemd/system/multi-user.target.wants/$unit_name"
        fi
    fi
}

copy_config_db() {
    local offline_root="$1"
    local src="/etc/sonic/config_db.json"
    local dst="$offline_root/etc/sonic/config_db.json"
    if [[ -f "$src" ]]; then
        ensure_dir "$offline_root/etc/sonic"
        if [[ -f "$dst" && "$DRY_RUN" -ne 1 ]]; then
            cp -a "$dst" "$dst.bak.$(date +%s)" || true
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: cp -a $src $dst"
        else
            cp -a "$src" "$dst"
        fi
        log "Copied config_db.json"
    else
        log "WARN: $src not found; skipping config_db copy"
    fi
}

copy_homes() {
    local offline_root="$1"
    ensure_dir "$offline_root/home"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: tar -C /home -cpf - . | tar -C $offline_root/home --numeric-owner -xpf -"
    else
        if declare -F copy_dir_tar >/dev/null 2>&1; then
            copy_dir_tar "/home" "$offline_root/home"
        else
            ( cd /home && tar -cpf - . ) | ( cd "$offline_root/home" && tar --numeric-owner -xpf - )
        fi
    fi
    log "Copied /home"
}

copy_ssh_settings_and_keys() {
    local offline_root="$1"
    if declare -F copy_ssh_tree_to_root >/dev/null 2>&1; then
        copy_ssh_tree_to_root "/" "$offline_root"
    else
        ensure_dir "$offline_root/etc/ssh"
        if [[ -f /etc/ssh/sshd_config ]]; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY-RUN: cp -a /etc/ssh/sshd_config $offline_root/etc/ssh/sshd_config"
            else
                cp -a /etc/ssh/sshd_config "$offline_root/etc/ssh/sshd_config"
            fi
        fi
        if [[ -d /etc/ssh/sshd_config.d ]]; then
            ensure_dir "$offline_root/etc/ssh/sshd_config.d"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY-RUN: cp -a /etc/ssh/sshd_config.d/. $offline_root/etc/ssh/sshd_config.d/"
            else
                cp -a /etc/ssh/sshd_config.d/. "$offline_root/etc/ssh/sshd_config.d/" || true
            fi
        fi
        for key in /etc/ssh/ssh_host_*; do
            [[ -f "$key" ]] || continue
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY-RUN: cp -a $key $offline_root/etc/ssh/"
            else
                cp -a "$key" "$offline_root/etc/ssh/"
            fi
        done
    fi
    if [[ -d /home ]]; then
        for homedir in /home/*; do
            [[ -d "$homedir" ]] || continue
            local rel
            rel=${homedir#/home/}
            ensure_dir "$offline_root/home/$rel"
            if [[ -d "$homedir/.ssh" ]]; then
                ensure_dir "$offline_root/home/$rel/.ssh"
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log "DRY-RUN: cp -a $homedir/.ssh/. $offline_root/home/$rel/.ssh/"
                else
                    cp -a "$homedir/.ssh/." "$offline_root/home/$rel/.ssh/" || true
                fi
            fi
        done
    fi
    log "Copied SSH config, host keys, and user keys"
}

copy_admin_password_hash() {
    local offline_root="$1"
    local user_name="admin"
    local line
    if ! grep -q '^admin:' /etc/shadow; then
        log "Admin user not found in /etc/shadow."
        if [[ "$NO_HANDHOLDING" -eq 1 ]]; then
            log "NO-HANDHOLDING: Skipping password hash migration prompt."
            user_name=""
        else
            read -r -p "Enter username to migrate password hash from (or leave blank to skip): " user_name || true
        fi
        if [[ -z "${user_name}" ]]; then
            log "Skipping password hash migration."
            return 0
        fi
    fi
    if ! line=$(grep -E "^${user_name}:" /etc/shadow || true); then
        log "WARN: user '${user_name}' not found in /etc/shadow; skipping password hash migration"
        return 0
    fi
    local shadow_dst="$offline_root/etc/shadow"
    if [[ ! -f "$shadow_dst" ]]; then
        log "WARN: $shadow_dst not found in offline image; skipping password hash migration"
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: cp -a $shadow_dst $shadow_dst.bak.$(date +%s)"
    else
        cp -a "$shadow_dst" "$shadow_dst.bak.$(date +%s)"
    fi
    if grep -qE "^${user_name}:" "$shadow_dst"; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: update password hash for $user_name in $shadow_dst"
        else
            sed -i "s%^${user_name}:[^:]*:%${line%%:*}:${line#*:}%" "$shadow_dst" || {
                sed -i "\%^${user_name}:% d" "$shadow_dst"
                echo "$line" >>"$shadow_dst"
            }
        fi
    else
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: append password hash for $user_name to $shadow_dst"
        else
            echo "$line" >>"$shadow_dst"
        fi
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: chmod 640 $shadow_dst; chown root:shadow $shadow_dst"
    else
        chmod 640 "$shadow_dst" || true
        chown root:shadow "$shadow_dst" || true
    fi
    log "Migrated password hash for user '${user_name}'"
}

update_fstab_for_flashdrive() {
    local offline_root="$1"
    local fstab_dst="$offline_root/etc/fstab"
    ensure_dir "$offline_root/etc"
    if [[ -f /etc/fstab ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: cp -a /etc/fstab $fstab_dst"
        else
            cp -a /etc/fstab "$fstab_dst"
        fi
    else
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: touch $fstab_dst"
        else
            touch "$fstab_dst"
        fi
    fi
    ensure_dir "$offline_root$FLASH_MOUNT"
    local src_dev
    if src_dev=$(findmnt -no SOURCE "$FLASH_MOUNT" 2>/dev/null); then
        local uuid
        uuid=$(blkid -s UUID -o value "$src_dev" 2>/dev/null || true)
        if [[ -n "$uuid" ]]; then
            local entry="UUID=$uuid $FLASH_MOUNT auto defaults,nofail,x-systemd.automount 0 0"
            if ! grep -q "UUID=$uuid" "$fstab_dst" 2>/dev/null; then
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log "DRY-RUN: append '$entry' to $fstab_dst"
                else
                    echo "$entry" >>"$fstab_dst"
                fi
                log "Added flashdrive UUID entry to fstab"
            else
                log "fstab already contains entry for flashdrive UUID $uuid"
            fi
        else
            log "WARN: Could not determine UUID for $src_dev; not modifying fstab"
        fi
    else
        log "WARN: $FLASH_MOUNT not currently mounted; copied fstab as-is"
    fi
}

install_brew_first_boot_service() {
    local offline_root="$1"
    ensure_dir "$offline_root/etc/systemd/system"
    ensure_dir "$offline_root/var/lib/sonic"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: write $offline_root/etc/systemd/system/brew-bootstrap.service"
    else
        cat >"$offline_root/etc/systemd/system/brew-bootstrap.service" <<'EOF'
[Unit]
Description=Bootstrap Homebrew on first boot
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/sonic/brew_bootstrap_done

[Service]
Type=oneshot
Environment=NONINTERACTIVE=1
Environment=CI=1
ExecStart=/bin/bash -lc 'set -e; if command -v curl >/dev/null 2>&1; then sh -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true; else echo "curl not found; skipping brew install"; fi; touch /var/lib/sonic/brew_bootstrap_done'

[Install]
WantedBy=multi-user.target
EOF
    fi
    enable_service_in_offline "$offline_root" "brew-bootstrap.service"
    log "Installed brew-bootstrap.service (first-boot)"
}

install_fancontrol_assets() {
    local offline_root="$1"
    local platform="$2"
    local platform_dir="$offline_root/usr/share/sonic/device/$platform"
    ensure_dir "$platform_dir"
    ensure_dir "$offline_root/etc/sonic/custom-fan"
    local custom_settings="$FLASH_MOUNT/fancontrol-custom4.bak"
    if [[ -f "$custom_settings" ]]; then
        if [[ -f "$platform_dir/fancontrol" && "$DRY_RUN" -ne 1 ]]; then
            cp -a "$platform_dir/fancontrol" "$platform_dir/fancontrol.bak.$(date +%s)" || true
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: cp -a $custom_settings $platform_dir/fancontrol"
            log "DRY-RUN: cp -a $custom_settings $offline_root/etc/sonic/custom-fan/fancontrol"
        else
            cp -a "$custom_settings" "$platform_dir/fancontrol"
            cp -a "$custom_settings" "$offline_root/etc/sonic/custom-fan/fancontrol"
        fi
        log "Installed custom fancontrol settings and saved persistent copy"
    else
        log "WARN: $custom_settings not found; leaving default fancontrol settings. The override service will do nothing unless /etc/sonic/custom-fan/fancontrol exists."
    fi
    if [[ -f "$FLASH_MOUNT/fancontrol" ]]; then
        ensure_dir "$offline_root/usr/sbin"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: cp -a $FLASH_MOUNT/fancontrol $offline_root/usr/sbin/fancontrol; chmod +x"
        else
            cp -a "$FLASH_MOUNT/fancontrol" "$offline_root/usr/sbin/fancontrol"
            chmod +x "$offline_root/usr/sbin/fancontrol" || true
        fi
        log "Copied fancontrol script"
    fi
    if [[ -f "$FLASH_MOUNT/fancontrol.service" ]]; then
        ensure_dir "$offline_root/etc/systemd/system"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: cp -a $FLASH_MOUNT/fancontrol.service $offline_root/etc/systemd/system/fancontrol.service"
        else
            cp -a "$FLASH_MOUNT/fancontrol.service" "$offline_root/etc/systemd/system/fancontrol.service"
        fi
        enable_service_in_offline "$offline_root" "fancontrol.service"
        log "Installed and enabled fancontrol.service from flashdrive"
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN: write $offline_root/etc/systemd/system/fancontrol-override.service"
    else
        cat >"$offline_root/etc/systemd/system/fancontrol-override.service" <<EOF
[Unit]
Description=Restore custom fancontrol and restart pmon
After=pmon.service network-online.target
Wants=pmon.service network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'set -e; SRC=/etc/sonic/custom-fan/fancontrol; DST=/usr/share/sonic/device/$platform/fancontrol; if [ -f "$SRC" ]; then cp -f "$SRC" "$DST"; systemctl restart pmon.service; else echo "fancontrol override: $SRC not present; skipping"; fi'

[Install]
WantedBy=multi-user.target
EOF
    fi
    enable_service_in_offline "$offline_root" "fancontrol-override.service"
    log "Installed fancontrol-override.service to enforce custom fan curve each boot"
}

write_marker_and_copy_self() {
    local offline_root="$1"
    if declare -F init_log_and_copy_self_to_root >/dev/null 2>&1; then
        LOGFILE=$(init_log_and_copy_self_to_root "$offline_root" "$SCRIPT_VERSION" "$0")
        log "Logging to $LOGFILE (version $SCRIPT_VERSION)"
    else
        ensure_dir "$offline_root/var/log"
        LOGFILE="$offline_root/var/log/sonic-offline-customize.log"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: would create log file at $LOGFILE"
        else
            touch "$LOGFILE"
            chmod 640 "$LOGFILE" || true
            echo "VERSION $SCRIPT_VERSION $(date -Is)" >>"$LOGFILE" || true
            log "Logging to $LOGFILE (version $SCRIPT_VERSION)"
        fi
        ensure_dir "$offline_root/usr/local/sbin"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: cp -a $0 $offline_root/usr/local/sbin/sonic-offline-customize.sh"
        else
            cp -a "$0" "$offline_root/usr/local/sbin/sonic-offline-customize.sh" || true
        fi
    fi
}

already_customized_exit_if_true() {
    local offline_root="$1"
    local marker="$offline_root/var/log/sonic-offline-customize.log"
    if [[ -f "$marker" ]] && grep -q "CUSTOMIZATION_COMPLETED" "$marker" 2>/dev/null; then
        echo "ALREADY"; return 0
    fi
    echo "NO"; return 0
}

set_next_boot_prompt() {
    local image_name="$1"
    read -r -p "Set next boot to '$image_name'? [y/N]: " ans || true
    case "${ans,,}" in
        y|yes)
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY-RUN: sonic-installer set-next-boot $image_name"
            elif sonic-installer set-next-boot "$image_name"; then
                log "Set next boot to $image_name"
            else
                log "WARN: Failed to set next boot via sonic-installer. You can run: sonic-installer set-next-boot '$image_name'"
            fi
            ;;
        *)
            log "Reminder: To switch on next reboot: sonic-installer set-next-boot '$image_name'"
            ;;
    esac
}

maybe_reboot_prompt() {
    read -r -p "Reboot now to cut over? [y/N]: " ans || true
    case "${ans,,}" in
        y|yes)
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log "DRY-RUN: reboot"
            else
                log "Rebooting..."
                sleep 1
                reboot
            fi
            ;;
        *)
            log "Not rebooting. Changes will take effect on next boot."
            ;;
    esac
}

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
    if [[ -z "$platform" ]]; then
        die "Failed to detect platform via sonic-cfggen; aborting."
    fi
    log "Detected platform: $platform"

    if declare -F copy_config_db_to_root >/dev/null 2>&1; then
        copy_config_db_to_root "$offline_root"
        log "Copied config_db.json"
    else
        copy_config_db "$offline_root"
    fi
    copy_homes "$offline_root"
    copy_ssh_settings_and_keys "$offline_root"
    if declare -F migrate_password_hash_to_root >/dev/null 2>&1; then
        migrate_password_hash_to_root "$offline_root" "admin"
        log "Migrated admin password hash"
    else
        copy_admin_password_hash "$offline_root"
    fi
    update_fstab_for_flashdrive "$offline_root"
    if [[ "$DISABLE_BREW" -eq 0 ]]; then
        if declare -F install_brew_first_boot_service_to_root >/dev/null 2>&1; then
            install_brew_first_boot_service_to_root "$offline_root"
        else
            install_brew_first_boot_service "$offline_root"
        fi
    else
        log "Skipping Homebrew bootstrap (flagged --no-brew)"
    fi
    if [[ "$DISABLE_FANCONTROL" -eq 0 ]]; then
        if declare -F install_fancontrol_assets_to_root >/dev/null 2>&1; then
            install_fancontrol_assets_to_root "$offline_root" "$platform"
        else
            install_fancontrol_assets "$offline_root" "$platform"
        fi
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