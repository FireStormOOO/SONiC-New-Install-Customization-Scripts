#!/usr/bin/env bash

set -euo pipefail

# SONiC offline image customization script
# Targeted for SONiC 202411 on Seastone DX010 (x86_64-cel_seastone-r0)
# Intended to run from the currently-booted image right after extracting a new image.
# Place this script on /media/flashdrive and run it from there as root.

# Configurable thresholds
RECENT_THRESHOLD_SECONDS=$((4 * 3600))
WARN_THRESHOLD_SECONDS=$((72 * 3600))

FLASH_MOUNT="/media/flashdrive"

required_binaries=(
    sonic-installer
    stat
    awk
    sed
    date
    rsync
    blkid
    findmnt
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
        t=$(stat -c %Y "$path" 2>/dev/null || echo 0)
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
    # Prefer fsroot timestamp if present
    if [[ -d "$dir/fsroot" ]]; then
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
        log "WARN: '$dir' modified ${hrs} hours ago. Proceeding anyway."
        return 0
    fi
    log "WARN: '$dir' modified more than 72 hours ago. If you intended to customize the newly installed image, consider re-running 'sonic-installer install <image>' first."
}

ensure_dir() {
    local d="$1"
    if [[ ! -d "$d" ]]; then
        mkdir -p "$d"
    fi
}

enable_service_in_offline() {
    local offline_root="$1"
    local unit_name="$2"
    ensure_dir "$offline_root/etc/systemd/system/multi-user.target.wants"
    if [[ -f "$offline_root/etc/systemd/system/$unit_name" ]]; then
        ln -sf "../$unit_name" "$offline_root/etc/systemd/system/multi-user.target.wants/$unit_name"
    fi
}

copy_config_db() {
    local offline_root="$1"
    local src="/etc/sonic/config_db.json"
    local dst="$offline_root/etc/sonic/config_db.json"
    if [[ -f "$src" ]]; then
        ensure_dir "$offline_root/etc/sonic"
        if [[ -f "$dst" ]]; then
            cp -a "$dst" "$dst.bak.$(date +%s)"
        fi
        cp -a "$src" "$dst"
        log "Copied config_db.json"
    else
        log "WARN: $src not found; skipping config_db copy"
    fi
}

copy_homes() {
    local offline_root="$1"
    ensure_dir "$offline_root/home"
    if command -v rsync >/dev/null 2>&1; then
        rsync -aHAX --numeric-ids --delete-excluded \
            --exclude '*/.cache/*' --exclude '*/.local/share/Trash/*' \
            /home/ "$offline_root/home/"
    else
        cp -a /home/. "$offline_root/home/"
    fi
    log "Copied /home"
}

copy_ssh_settings_and_keys() {
    local offline_root="$1"
    ensure_dir "$offline_root/etc/ssh"
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp -a /etc/ssh/sshd_config "$offline_root/etc/ssh/sshd_config"
    fi
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        ensure_dir "$offline_root/etc/ssh/sshd_config.d"
        cp -a /etc/ssh/sshd_config.d/. "$offline_root/etc/ssh/sshd_config.d/" || true
    fi
    # Preserve host keys to avoid client warnings
    for key in /etc/ssh/ssh_host_*; do
        [[ -f "$key" ]] || continue
        cp -a "$key" "$offline_root/etc/ssh/"
    done

    # Copy user authorized_keys
    if [[ -d /home ]]; then
        for homedir in /home/*; do
            [[ -d "$homedir" ]] || continue
            local rel
            rel=${homedir#/home/}
            ensure_dir "$offline_root/home/$rel"
            if [[ -d "$homedir/.ssh" ]]; then
                ensure_dir "$offline_root/home/$rel/.ssh"
                cp -a "$homedir/.ssh/." "$offline_root/home/$rel/.ssh/" || true
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
        read -r -p "Enter username to migrate password hash from (or leave blank to skip): " user_name || true
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
    cp -a "$shadow_dst" "$shadow_dst.bak.$(date +%s)"
    # Replace or append the line for the user
    if grep -qE "^${user_name}:" "$shadow_dst"; then
        sed -i "s%^${user_name}:[^:]*:%${line%%:*}:${line#*:}%" "$shadow_dst" || {
            # Fallback: replace whole line
            sed -i "\%^${user_name}:% d" "$shadow_dst"
            echo "$line" >>"$shadow_dst"
        }
    else
        echo "$line" >>"$shadow_dst"
    fi
    chmod 640 "$shadow_dst" || true
    chown root:shadow "$shadow_dst" || true
    log "Migrated password hash for user '${user_name}'"
}

update_fstab_for_flashdrive() {
    local offline_root="$1"
    local fstab_dst="$offline_root/etc/fstab"
    ensure_dir "$offline_root/etc"
    if [[ -f /etc/fstab ]]; then
        cp -a /etc/fstab "$fstab_dst"
    else
        touch "$fstab_dst"
    fi

    ensure_dir "$offline_root$FLASH_MOUNT"

    local src_dev
    if src_dev=$(findmnt -no SOURCE "$FLASH_MOUNT" 2>/dev/null); then
        local uuid
        uuid=$(blkid -s UUID -o value "$src_dev" 2>/dev/null || true)
        if [[ -n "$uuid" ]]; then
            local entry="UUID=$uuid $FLASH_MOUNT auto defaults,nofail,x-systemd.automount 0 0"
            if ! grep -q "UUID=$uuid" "$fstab_dst" 2>/dev/null; then
                echo "$entry" >>"$fstab_dst"
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
    enable_service_in_offline "$offline_root" "brew-bootstrap.service"
    log "Installed brew-bootstrap.service (first-boot)"
}

install_fancontrol_assets() {
    local offline_root="$1"
    local platform="$2"
    local platform_dir="$offline_root/usr/share/sonic/device/$platform"
    ensure_dir "$platform_dir"

    # Settings file from flashdrive
    local custom_settings="$FLASH_MOUNT/fancontrol-custom4.bak"
    if [[ -f "$custom_settings" ]]; then
        if [[ -f "$platform_dir/fancontrol" ]]; then
            cp -a "$platform_dir/fancontrol" "$platform_dir/fancontrol.bak.$(date +%s)"
        fi
        cp -a "$custom_settings" "$platform_dir/fancontrol"
        log "Installed custom fancontrol settings to $platform_dir/fancontrol"
    else
        log "WARN: $custom_settings not found; leaving default fancontrol settings"
    fi

    # Optional script and service from flashdrive
    if [[ -f "$FLASH_MOUNT/fancontrol" ]]; then
        ensure_dir "$offline_root/usr/sbin"
        cp -a "$FLASH_MOUNT/fancontrol" "$offline_root/usr/sbin/fancontrol"
        chmod +x "$offline_root/usr/sbin/fancontrol" || true
        log "Copied fancontrol script"
    fi
    if [[ -f "$FLASH_MOUNT/fancontrol.service" ]]; then
        ensure_dir "$offline_root/etc/systemd/system"
        cp -a "$FLASH_MOUNT/fancontrol.service" "$offline_root/etc/systemd/system/fancontrol.service"
        enable_service_in_offline "$offline_root" "fancontrol.service"
        log "Installed and enabled fancontrol.service from flashdrive"
    else
        # Ensure pmon is bounced once on first boot so new settings take effect
        cat >"$offline_root/etc/systemd/system/fancontrol-apply.service" <<'EOF'
[Unit]
Description=Apply custom fancontrol settings by restarting pmon once
After=multi-user.target pmon.service
Requires=pmon.service
ConditionPathExists=!/etc/sonic/.fancontrol_applied

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl restart pmon.service && touch /etc/sonic/.fancontrol_applied'

[Install]
WantedBy=multi-user.target
EOF
        enable_service_in_offline "$offline_root" "fancontrol-apply.service"
        log "Installed fancontrol-apply.service to restart pmon once on next boot"
    fi
}

write_marker_and_copy_self() {
    local offline_root="$1"
    ensure_dir "$offline_root/var/log"
    LOGFILE="$offline_root/var/log/sonic-offline-customize.log"
    touch "$LOGFILE"
    chmod 640 "$LOGFILE" || true
    log "Logging to $LOGFILE"

    # Copy this script into the offline image for traceability
    ensure_dir "$offline_root/usr/local/sbin"
    cp -a "$0" "$offline_root/usr/local/sbin/sonic-offline-customize.sh" || true
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
            if sonic-installer set-next-boot "$image_name"; then
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
            log "Rebooting..."
            sleep 1
            reboot
            ;;
        *)
            log "Not rebooting. Changes will take effect on next boot into the target image."
            ;;
    esac
}

main() {
    need_root
    check_binaries || true

    local target_dir
    target_dir=$(detect_newest_offline_image_dir) || die "Could not find any /host/image-* directories"
    verify_recent_install "$target_dir"

    # Resolve offline root (fsroot within image dir if present)
    local offline_root
    if [[ -d "$target_dir/fsroot" ]]; then
        offline_root="$target_dir/fsroot"
    else
        offline_root="$target_dir"
    fi

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
    install_brew_first_boot_service "$offline_root"
    install_fancontrol_assets "$offline_root" "$platform"

    local image_name
    image_name=$(image_dir_to_name "$target_dir")
    log "Target image name: $image_name"

    set_next_boot_prompt "$image_name"
    maybe_reboot_prompt

    # Mark completion for idempotency
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "CUSTOMIZATION_COMPLETED $(date -Is)" >>"$LOGFILE" || true
    else
        ensure_dir "$offline_root/var/log" && echo "CUSTOMIZATION_COMPLETED $(date -Is)" >>"$offline_root/var/log/sonic-offline-customize.log" || true
    fi
    log "Done."
}

main "$@"

