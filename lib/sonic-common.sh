#!/usr/bin/env bash

# Common helpers for SONiC customization scripts
# Note: Each function is defined only if not already present to avoid conflicts

# Ensure directory exists
if ! declare -F ensure_dir >/dev/null 2>&1; then
ensure_dir() {
	local d="$1"
	if [[ ! -d "$d" ]]; then
		mkdir -p "$d"
	fi
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
		ln -sf "../$unit_name" "$offline_root/etc/systemd/system/multi-user.target.wants/$unit_name"
	fi
}
fi

# Copy a directory tree preserving ownership/permissions via tar. Args: SRC_DIR DST_DIR
if ! declare -F copy_dir_tar >/dev/null 2>&1; then
copy_dir_tar() {
	local src="$1" dst="$2"
	ensure_dir "$dst"
	( cd "$src" && tar -cpf - . ) | ( cd "$dst" && tar --numeric-owner -xpf - )
}
fi

# Update offline fstab with flashdrive UUID entry if mounted. FLASH_MOUNT can be overridden by env.
if ! declare -F update_fstab_for_flashdrive >/dev/null 2>&1; then
update_fstab_for_flashdrive() {
	local offline_root="$1"
	local flash_mount="${FLASH_MOUNT:-/media/flashdrive}"
	local fstab_dst="$offline_root/etc/fstab"
	ensure_dir "$offline_root/etc"
	if [[ -f /etc/fstab ]]; then cp -a /etc/fstab "$fstab_dst"; else : >"$fstab_dst"; fi
	ensure_dir "$offline_root$flash_mount"
	local src_dev uuid
	if src_dev=$(findmnt -no SOURCE "$flash_mount" 2>/dev/null); then
		uuid=$(blkid -s UUID -o value "$src_dev" 2>/dev/null || true)
		if [[ -n "$uuid" ]]; then
			local entry="UUID=$uuid $flash_mount auto defaults,nofail,x-systemd.automount 0 0"
			grep -q "UUID=$uuid" "$fstab_dst" 2>/dev/null || echo "$entry" >>"$fstab_dst"
		fi
	fi
}
fi

