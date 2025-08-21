#!/usr/bin/env bash

set -euo pipefail

# SONiC offline customization environment validator
# Verifies assumptions before running sonic-offline-customize.sh

RECENT_THRESHOLD_SECONDS=$((4 * 3600))
WARN_THRESHOLD_SECONDS=$((72 * 3600))
FLASH_MOUNT="/media/flashdrive"

required_binaries=(
	sonic-installer
	stat
	awk
	sed
	date
	blkid
	findmnt
	df
	du
	diff
)

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; WARN_COUNT=$((WARN_COUNT+1)); }
fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
pass() { echo "[ OK ] $*"; PASS_COUNT=$((PASS_COUNT+1)); }

need_root() {
	if [[ ${EUID} -ne 0 ]]; then
		fail "Must run as root"
		exit 1
	fi
	pass "Running as root"
}

check_binaries() {
	local missing=0
	for bin in "${required_binaries[@]}"; do
		if ! command -v "$bin" >/dev/null 2>&1; then
			warn "Missing binary: $bin"
			missing=1
		else
			:
		fi
	done
	if [[ $missing -eq 0 ]]; then pass "All required binaries present"; fi
}

detect_platform() {
	local platform=""
	if command -v sonic-cfggen >/dev/null 2>&1; then
		platform=$(sonic-cfggen -H -v DEVICE_METADATA.localhost.platform 2>/dev/null || true)
	fi
	if [[ -z "$platform" ]]; then
		warn "Could not detect platform via sonic-cfggen"
		platform="unknown"
	else
		pass "Detected platform: $platform"
	fi
	echo "$platform"
}

detect_sonic_version() {
	local ver=""
	if [[ -f /etc/sonic/sonic_version.yml ]]; then
		ver=$(grep -E '^build_version:' /etc/sonic/sonic_version.yml | awk '{print $2}' || true)
	elif command -v show >/dev/null 2>&1; then
		ver=$(show version 2>/dev/null | awk -F: '/SONiC Software Version/ {gsub(/^ +| +$/,"",$2); print $2}' || true)
	fi
	if [[ -n "$ver" ]]; then
		log "SONiC version: $ver"
		case "$ver" in
			*202411*) pass "Targeted SONiC version detected (202411)" ;;
			*) warn "Version differs from targeted 202411: $ver" ;;
		esac
	else
		warn "Unable to determine SONiC version"
	fi
}

detect_newest_image() {
	local newest="" mtime=0 path
	for path in /host/image-*; do
		[[ -d "$path" ]] || continue
		local t
		if [[ -d "$path/fsroot" ]]; then
			t=$(stat -c %Y "$path/fsroot" 2>/dev/null || echo 0)
		else
			t=$(stat -c %Y "$path" 2>/dev/null || echo 0)
		fi
		if [[ "$t" -gt "$mtime" ]]; then mtime=$t; newest=$path; fi
	done
	[[ -n "$newest" ]] || return 1
	echo "$newest"
}

resolve_offline_root() {
	local dir="$1"
	if [[ -d "$dir/rw" ]]; then echo "$dir/rw"; elif [[ -d "$dir/fsroot" ]]; then echo "$dir/fsroot"; else echo "$dir"; fi
}

check_recent_install() {
	local dir="$1" ts now age
	if [[ -d "$dir/fsroot" ]]; then ts=$(stat -c %Y "$dir/fsroot"); else ts=$(stat -c %Y "$dir"); fi
	now=$(date +%s)
	age=$((now - ts))
	if [[ $age -le $RECENT_THRESHOLD_SECONDS ]]; then
		pass "Offline image looks recent (<= 4h)"
	elif [[ $age -le $WARN_THRESHOLD_SECONDS ]]; then
		warn "Offline image modified ~$((age/3600))h ago"
	else
		warn "Offline image modified >72h ago"
	fi
}

check_flashdrive() {
	if findmnt -no SOURCE "$FLASH_MOUNT" >/dev/null 2>&1; then
		local src uuid
		src=$(findmnt -no SOURCE "$FLASH_MOUNT")
		uuid=$(blkid -s UUID -o value "$src" 2>/dev/null || true)
		if [[ -n "$uuid" ]]; then
			pass "Flashdrive mounted at $FLASH_MOUNT with UUID $uuid"
		else
			warn "Flashdrive mounted at $FLASH_MOUNT but UUID not found"
		fi
		# Expected files
		[[ -f "$FLASH_MOUNT/fancontrol-custom4.bak" ]] && pass "Found fancontrol-custom4.bak on flash" || warn "Missing fancontrol-custom4.bak on flash"
		[[ -f "$FLASH_MOUNT/fancontrol" ]] && log "Found optional fancontrol script" || true
		[[ -f "$FLASH_MOUNT/fancontrol.service" ]] && log "Found optional fancontrol.service" || true
		[[ -f "$FLASH_MOUNT/sonic-offline-customize.sh" ]] && log "Found customize script on flash" || true
	else
		warn "Flashdrive not mounted at $FLASH_MOUNT"
	fi
}

check_running_vs_saved_config() {
	if command -v show >/dev/null 2>&1 && [[ -f /etc/sonic/config_db.json ]]; then
		if running=$(show runningconfiguration all 2>/dev/null | sed -n '/^{/,$p'); then
			local tmp_run tmp_save
			tmp_run=$(mktemp); tmp_save=$(mktemp)
			echo "$running" >"$tmp_run"
			sed 's/[[:space:]]//g' /etc/sonic/config_db.json >"$tmp_save"
			sed -i 's/[[:space:]]//g' "$tmp_run"
			if ! diff -q "$tmp_run" "$tmp_save" >/dev/null 2>&1; then
				warn "Running config differs from saved config_db.json (list order may differ)"
			else
				pass "Running config matches saved config_db.json (ignoring whitespace)"
			fi
			rm -f "$tmp_run" "$tmp_save" || true
		fi
	else
		warn "Cannot compare running vs saved config (missing 'show' or config_db.json)"
	fi
}

check_users_shadow() {
	if getent passwd admin >/dev/null 2>&1; then
		pass "Admin user present on current system"
	else
		warn "Admin user not present on current system"
	fi
	[[ -r /etc/shadow ]] && pass "/etc/shadow readable" || warn "/etc/shadow not readable"
}

check_offline_layout() {
	local offline_root="$1" platform="$2"
	if mountpoint -q /newroot; then
		[[ -d "$offline_root/etc" ]] && pass "Overlay etc/ exists" || fail "Overlay etc/ missing"
		[[ -f "$offline_root/etc/sonic/config_db.json" ]] && log "Overlay has config_db.json" || log "Overlay config_db.json not found (will be copied)"
		[[ -f "$offline_root/etc/shadow" ]] && pass "Overlay /etc/shadow present" || warn "Overlay /etc/shadow missing"
		[[ -d "$offline_root/usr/share/sonic/device/$platform" ]] && pass "Platform dir exists in overlay" || warn "Platform dir missing in overlay"
	else
		if [[ -d "$offline_root/etc" ]]; then
			pass "Image etc/ exists"
		else
			warn "Image etc/ missing (expected for squashfs without fsroot). Prepare overlay to get a writable root at /newroot."
		fi
		[[ -d "$offline_root/usr/share/sonic/device/$platform" ]] && pass "Platform dir exists in image" || warn "Platform dir missing in image"
	fi
}

check_space_for_home_copy() {
	local target_dir="$1"
	local avail_kb homes_kb
	avail_kb=$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')
	homes_kb=$(du -sk /home 2>/dev/null | awk '{print $1}')
	if [[ -z "$homes_kb" ]]; then
		warn "Could not size /home; skipping space check"
		return
	fi
	# Require 1.2x headroom
	local need_kb=$((homes_kb + homes_kb/5))
	if [[ "$avail_kb" -ge "$need_kb" ]]; then
		pass "Sufficient space on /host for copying /home (need ~${need_kb}K, have ${avail_kb}K)"
	else
		warn "Potentially insufficient space for /home copy (need ~${need_kb}K, have ${avail_kb}K)"
	fi
}

check_writable_offline() {
	local offline_root="$1"
	local probe="$offline_root/.__write_probe__.$$"
	if ( umask 022 && : >"$probe" ) 2>/dev/null; then
		rm -f "$probe" || true
		pass "Offline root appears writable"
	else
		fail "Cannot write into offline root: $offline_root"
	fi
}

check_services_present() {
	# Ensure pmon service known to systemd (current OS)
	if systemctl list-unit-files pmon.service >/dev/null 2>&1; then
		pass "pmon.service present on current system"
	else
		warn "pmon.service not found on current system"
	fi
}

main() {
	need_root
	check_binaries
	detect_sonic_version
	local platform
	platform=$(detect_platform)
	[[ "$platform" == "x86_64-cel_seastone-r0" ]] && pass "Expected platform detected (x86_64-cel_seastone-r0)" || warn "Platform differs: $platform"

	local target_dir
	if ! target_dir=$(detect_newest_image); then
		fail "No /host/image-* directories found"
		echo ""; echo "Summary: $PASS_COUNT OK, $WARN_COUNT WARN, $FAIL_COUNT FAIL"; exit 1
	fi
	log "Newest image: $target_dir"
	local offline_root
	offline_root=$(resolve_offline_root "$target_dir")
	log "Offline root resolved to: $offline_root"
	check_recent_install "$target_dir"
	check_offline_layout "$offline_root" "$platform"
	check_writable_offline "$offline_root"
	check_space_for_home_copy "$target_dir"
	check_users_shadow
	check_flashdrive
	check_running_vs_saved_config
	check_services_present

	echo ""
	echo "Summary: $PASS_COUNT OK, $WARN_COUNT WARN, $FAIL_COUNT FAIL"
	if [[ $FAIL_COUNT -gt 0 ]]; then
		exit 2
	fi
}

main "$@"