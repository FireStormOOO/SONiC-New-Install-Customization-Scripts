#!/usr/bin/env bash

# Common helpers for SONiC customization scripts
# Note: Each function is defined only if not already present to avoid conflicts

# Standard version for all scripts
SONIC_SCRIPTS_VERSION="2025.08.20-5"

# Standard script initialization
if ! declare -F sonic_script_init >/dev/null 2>&1; then
sonic_script_init() {
    local script_name="${1:-$(basename "$0")}"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    export SCRIPT_DIR
    [[ ${EUID} -eq 0 ]] || { echo "ERROR: Must run as root" >&2; exit 1; }
}
fi

# Standard logging function
if ! declare -F log >/dev/null 2>&1; then
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fi

# Standard error function
if ! declare -F die >/dev/null 2>&1; then
die() { log "ERROR: $*"; exit 1; }
fi

# Standard root check function
if ! declare -F need_root >/dev/null 2>&1; then
need_root() { [[ ${EUID} -eq 0 ]] || die "Must run as root"; }
fi

# Internal logger (falls back to echo)
_sonic_common_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$@"
    else
        echo "$@"
    fi
}

# DRY-RUN helpers
if ! declare -F dry >/dev/null 2>&1; then
dry() {
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        _sonic_common_log "DRY-RUN: $*"
    else
        "$@"
    fi
}
fi

if ! declare -F drysh >/dev/null 2>&1; then
drysh() {
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        _sonic_common_log "DRY-RUN: $*"
    else
        bash -lc "$*"
    fi
}
fi

# Enhanced dry run helpers for common operations
if ! declare -F dry_cp >/dev/null 2>&1; then
dry_cp() {
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        _sonic_common_log "DRY-RUN: cp $*"
    else
        cp "$@"
    fi
}
fi

if ! declare -F dry_touch >/dev/null 2>&1; then
dry_touch() {
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        _sonic_common_log "DRY-RUN: touch $*"
    else
        touch "$@"
    fi
}
fi

if ! declare -F dry_chmod >/dev/null 2>&1; then
dry_chmod() {
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        _sonic_common_log "DRY-RUN: chmod $*"
    else
        chmod "$@"
    fi
}
fi

if ! declare -F dry_echo_append >/dev/null 2>&1; then
dry_echo_append() {
    local content="$1" file="$2"
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        _sonic_common_log "DRY-RUN: echo '$content' >> $file"
    else
        echo "$content" >> "$file"
    fi
}
fi

if ! declare -F dry_exec >/dev/null 2>&1; then
dry_exec() {
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        _sonic_common_log "DRY-RUN: $*"
    else
        "$@"
    fi
}
fi

# Ensure directory exists (DRY-RUN aware)
if ! declare -F ensure_dir >/dev/null 2>&1; then
ensure_dir() {
	local d="$1"
	[[ -d "$d" ]] || dry mkdir -p "$d"
}
fi

# Detect platform string via sonic-cfggen
if ! declare -F detect_platform >/dev/null 2>&1; then
detect_platform() {
	local platform=""
	if command -v sonic-cfggen >/dev/null 2>&1; then
		platform=$(sonic-cfggen -H -v DEVICE_METADATA.localhost.platform 2>/dev/null || true)
	fi
	[[ -n "$platform" ]] || platform="unknown"
	echo "$platform"
}
fi

# Newest image dir under /host by mtime (prefers rw/ then fsroot/ then dir)
if ! declare -F detect_newest_image_dir >/dev/null 2>&1; then
detect_newest_image_dir() {
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
fi

# Backward-compatible alias used by some scripts
if ! declare -F detect_newest_offline_image_dir >/dev/null 2>&1; then
detect_newest_offline_image_dir() { detect_newest_image_dir; }
fi

# Convert /host/image-XYZ to XYZ
if ! declare -F image_dir_to_name >/dev/null 2>&1; then
image_dir_to_name() {
	local dir="$1"
	basename "$dir" | sed 's/^image-//'
}
fi

# Detect current image dir by parsing overlay upperdir from mount output
if ! declare -F detect_current_image_dir >/dev/null 2>&1; then
detect_current_image_dir() {
	local line
	line=$(mount | awk -F'[ ,]' '/ on \/ type overlay / && /upperdir=/{print $0; exit}')
	if [[ -n "$line" ]]; then
		local upper dir
		upper=$(echo "$line" | sed -n 's/.*upperdir=\([^,]*\).*/\1/p')
		dir=$(dirname "$upper"); dir=$(dirname "$dir")
		[[ -d "$dir" ]] && echo "$dir" && return 0
	fi
	detect_newest_image_dir
}
fi

# Enable a systemd unit inside offline root (multi-user target)
if ! declare -F enable_service_in_offline >/dev/null 2>&1; then
enable_service_in_offline() {
	local offline_root="$1" unit_name="$2"
	ensure_dir "$offline_root/etc/systemd/system/multi-user.target.wants"
	if [[ -f "$offline_root/etc/systemd/system/$unit_name" ]]; then
		dry ln -sf "../$unit_name" "$offline_root/etc/systemd/system/multi-user.target.wants/$unit_name"
	fi
}
fi

# Copy a directory tree preserving ownership/permissions via tar. Args: SRC_DIR DST_DIR
if ! declare -F copy_dir_tar >/dev/null 2>&1; then
copy_dir_tar() {
	local src="$1" dst="$2"
	ensure_dir "$dst"
	if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
		_sonic_common_log "DRY-RUN: tar -C $src -cpf - . | tar -C $dst --numeric-owner -xpf -"
	else
		( cd "$src" && tar -cpf - . ) | ( cd "$dst" && tar --numeric-owner -xpf - )
	fi
}
fi

# Copy system SSH server config and host keys from a source root into a target root
if ! declare -F copy_ssh_tree_to_root >/dev/null 2>&1; then
copy_ssh_tree_to_root() {
	local src_root="$1" dst_root="$2"
	if [[ -f "$src_root/etc/ssh/sshd_config" || -d "$src_root/etc/ssh/sshd_config.d" ]]; then
		ensure_dir "$dst_root/etc/ssh"
		if [[ -f "$src_root/etc/ssh/sshd_config" ]]; then
			if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
				_sonic_common_log "DRY-RUN: cp -a $src_root/etc/ssh/sshd_config $dst_root/etc/ssh/"
			else
				cp -a "$src_root/etc/ssh/sshd_config" "$dst_root/etc/ssh/" || true
			fi
		fi
		if [[ -d "$src_root/etc/ssh/sshd_config.d" ]]; then
			ensure_dir "$dst_root/etc/ssh/sshd_config.d"
			if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
				_sonic_common_log "DRY-RUN: cp -a $src_root/etc/ssh/sshd_config.d/. $dst_root/etc/ssh/sshd_config.d/"
			else
				cp -a "$src_root/etc/ssh/sshd_config.d/." "$dst_root/etc/ssh/sshd_config.d/" || true
			fi
		fi
		for key in "$src_root"/etc/ssh/ssh_host_*; do
			[[ -f "$key" ]] || continue
			if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
				_sonic_common_log "DRY-RUN: cp -a $key $dst_root/etc/ssh/"
			else
				cp -a "$key" "$dst_root/etc/ssh/" || true
			fi
		done
	fi
}
fi

# Upsert a full passwd/shadow line for the given user in target shadow file
if ! declare -F upsert_shadow_line >/dev/null 2>&1; then
upsert_shadow_line() {
	local target_shadow="$1" user_name="$2" full_line="$3"
	[[ -f "$target_shadow" ]] || return 1
	if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
		_sonic_common_log "DRY-RUN: cp -a $target_shadow $target_shadow.bak.$(date +%s)"
	else
		cp -a "$target_shadow" "$target_shadow.bak.$(date +%s)" || true
	fi
	if grep -qE "^${user_name}:" "$target_shadow"; then
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: update shadow entry for $user_name in $target_shadow"
		else
			sed -i "s%^${user_name}:[^:]*:%${full_line%%:*}:${full_line#*:}%" "$target_shadow" || {
				sed -i "\%^${user_name}:% d" "$target_shadow"; echo "$full_line" >>"$target_shadow"
			}
		fi
	else
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: append shadow entry for $user_name to $target_shadow"
		else
			echo "$full_line" >>"$target_shadow"
		fi
	fi
	if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
		_sonic_common_log "DRY-RUN: chmod 640 $target_shadow; chown root:shadow $target_shadow"
	else
		chmod 640 "$target_shadow" 2>/dev/null || true
		chown root:shadow "$target_shadow" 2>/dev/null || true
	fi
}
fi

# Update offline fstab with flashdrive UUID entry if mounted. FLASH_MOUNT can be overridden by env.
if ! declare -F update_fstab_for_flashdrive >/dev/null 2>&1; then
update_fstab_for_flashdrive() {
	local offline_root="$1"
	local flash_mount="${FLASH_MOUNT:-/media/flashdrive}"
	local fstab_dst="$offline_root/etc/fstab"
	ensure_dir "$offline_root/etc"
	if [[ -f /etc/fstab ]]; then
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: cp -a /etc/fstab $fstab_dst"
		else
			cp -a /etc/fstab "$fstab_dst"
		fi
	else
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: : > $fstab_dst"
		else
			: >"$fstab_dst"
		fi
	fi
	ensure_dir "$offline_root$flash_mount"
	local src_dev uuid
	if src_dev=$(findmnt -no SOURCE "$flash_mount" 2>/dev/null); then
		uuid=$(blkid -s UUID -o value "$src_dev" 2>/dev/null || true)
		if [[ -n "$uuid" ]]; then
			local entry="UUID=$uuid $flash_mount auto defaults,nofail,x-systemd.automount 0 0"
			if ! grep -q "UUID=$uuid" "$fstab_dst" 2>/dev/null; then
				if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
					_sonic_common_log "DRY-RUN: append '$entry' to $fstab_dst"
				else
					echo "$entry" >>"$fstab_dst"
				fi
			fi
		fi
	fi
}
fi

# Create brew-bootstrap.service in offline root and enable it
if ! declare -F install_brew_first_boot_service_to_root >/dev/null 2>&1; then
install_brew_first_boot_service_to_root() {
	local offline_root="$1"
	ensure_dir "$offline_root/etc/systemd/system"
	ensure_dir "$offline_root/var/lib/sonic"
	if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
		_sonic_common_log "DRY-RUN: write $offline_root/etc/systemd/system/brew-bootstrap.service"
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
}
fi

# Install fancontrol assets and override unit into offline root
if ! declare -F install_fancontrol_assets_to_root >/dev/null 2>&1; then
install_fancontrol_assets_to_root() {
	local offline_root="$1" platform="$2" flash_mount="${FLASH_MOUNT:-/media/flashdrive}"
	local platform_dir="$offline_root/usr/share/sonic/device/$platform"
	ensure_dir "$platform_dir"
	ensure_dir "$offline_root/etc/sonic/custom-fan"
	local custom_settings="$flash_mount/fancontrol-custom4.bak"
	if [[ -f "$custom_settings" ]]; then
		if [[ -f "$platform_dir/fancontrol" && "${DRY_RUN:-0}" -ne 1 ]]; then
			cp -a "$platform_dir/fancontrol" "$platform_dir/fancontrol.bak.$(date +%s)" || true
		fi
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: cp -a $custom_settings $platform_dir/fancontrol"
			_sonic_common_log "DRY-RUN: cp -a $custom_settings $offline_root/etc/sonic/custom-fan/fancontrol"
		else
			cp -a "$custom_settings" "$platform_dir/fancontrol"
			cp -a "$custom_settings" "$offline_root/etc/sonic/custom-fan/fancontrol"
		fi
	fi
	if [[ -f "$flash_mount/fancontrol" ]]; then
		ensure_dir "$offline_root/usr/sbin"
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: cp -a $flash_mount/fancontrol $offline_root/usr/sbin/fancontrol; chmod +x"
		else
			cp -a "$flash_mount/fancontrol" "$offline_root/usr/sbin/fancontrol"
			chmod +x "$offline_root/usr/sbin/fancontrol" || true
		fi
	fi
	# Override service
	if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
		_sonic_common_log "DRY-RUN: write $offline_root/etc/systemd/system/fancontrol-override.service"
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
}
fi

# Copy config_db.json into offline root
if ! declare -F copy_config_db_to_root >/dev/null 2>&1; then
copy_config_db_to_root() {
	local offline_root="$1" src="/etc/sonic/config_db.json" dst="$offline_root/etc/sonic/config_db.json"
	if [[ -f "$src" ]]; then
		ensure_dir "$offline_root/etc/sonic"
		if [[ -f "$dst" && "${DRY_RUN:-0}" -ne 1 ]]; then
			cp -a "$dst" "$dst.bak.$(date +%s)" || true
		fi
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: cp -a $src $dst"
		else
			cp -a "$src" "$dst"
		fi
	fi
}
fi

# Initialize log file under offline root and copy self script for traceability
if ! declare -F init_log_and_copy_self_to_root >/dev/null 2>&1; then
init_log_and_copy_self_to_root() {
	local offline_root="$1" script_version="$2" self_path="$3"
	ensure_dir "$offline_root/var/log"
	local logfile="$offline_root/var/log/sonic-offline-customize.log"
	if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
		_sonic_common_log "DRY-RUN: touch $logfile; chmod 640; append version"
	else
		touch "$logfile"
		chmod 640 "$logfile" || true
		echo "VERSION $script_version $(date -Is)" >>"$logfile" || true
	fi
	ensure_dir "$offline_root/usr/local/sbin"
	if [[ -n "$self_path" ]]; then
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: cp -a $self_path $offline_root/usr/local/sbin/sonic-offline-customize.sh"
		else
			cp -a "$self_path" "$offline_root/usr/local/sbin/sonic-offline-customize.sh" || true
		fi
	fi
	echo "$logfile"
}
fi

# Migrate password hash for a user from current /etc/shadow into offline root's /etc/shadow
if ! declare -F migrate_password_hash_to_root >/dev/null 2>&1; then
migrate_password_hash_to_root() {
	local offline_root="$1" user_name="${2:-admin}"
	if [[ ! -r /etc/shadow ]]; then
		_sonic_common_log "WARN: /etc/shadow not readable; skipping password migration"
		return 0
	fi
	if ! grep -qE "^${user_name}:" /etc/shadow 2>/dev/null; then
		_sonic_common_log "WARN: user '$user_name' not found in /etc/shadow; skipping password migration"
		return 0
	fi
	local line
	line=$(grep -E "^${user_name}:" /etc/shadow)
	local target_shadow="$offline_root/etc/shadow"
	if [[ ! -f "$target_shadow" ]]; then
		_sonic_common_log "WARN: $target_shadow not found; skipping password migration"
		return 0
	fi
	if declare -F upsert_shadow_line >/dev/null 2>&1; then
		upsert_shadow_line "$target_shadow" "$user_name" "$line"
	else
		if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
			_sonic_common_log "DRY-RUN: cp -a $target_shadow $target_shadow.bak.$(date +%s)"
			_sonic_common_log "DRY-RUN: update or append shadow entry for $user_name"
		else
			cp -a "$target_shadow" "$target_shadow.bak.$(date +%s)" || true
			if grep -qE "^${user_name}:" "$target_shadow"; then
				sed -i "s%^${user_name}:[^:]*:%${line%%:*}:${line#*:}%" "$target_shadow" || {
					sed -i "\%^${user_name}:% d" "$target_shadow"; echo "$line" >>"$target_shadow"
				}
			else
				echo "$line" >>"$target_shadow"
			fi
			chmod 640 "$target_shadow" 2>/dev/null || true
			chown root:shadow "$target_shadow" 2>/dev/null || true
		fi
	fi
}
fi


