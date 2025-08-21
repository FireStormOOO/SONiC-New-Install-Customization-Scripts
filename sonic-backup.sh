#!/usr/bin/env bash

set -euo pipefail

# SONiC backup/restore helper
# Creates a tarball with key configuration and an accompanying manifest

SCRIPT_VERSION="2025.08.20-2"

usage() {
    cat <<USAGE
Usage:
  $0 backup   --output <path.tar.gz> [--source-root /]
  $0 restore  --input <path.tar.gz> --target-root </newroot>

Options:
  --output        Path to write tar.gz (for backup)
  --source-root   Root to back up from (default: /)
  --input         Path to read tar.gz (for restore)
  --target-root   Destination root to restore into (e.g., /newroot)
  -h, --help      Show this help
USAGE
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_root() {
    if [[ ${EUID} -ne 0 ]]; then die "Must run as root"; fi
}

# source common helpers
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/sonic-common.sh" ]]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/sonic-common.sh"
fi

# prefer library detect_platform
declare -F detect_platform >/dev/null 2>&1 || detect_platform() { echo unknown; }

create_backup() {
    local out="$1" source_root="${2:-/}"
    [[ -n "$out" ]] || die "--output is required"
    [[ -d "$source_root" ]] || die "--source-root not a directory"

    local work
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    local platform
    platform=$(detect_platform)

    mkdir -p "$work/data" "$work/meta"

    # Collect files
    if [[ -f "$source_root/etc/sonic/config_db.json" ]]; then
        mkdir -p "$work/data/etc/sonic"
        cp -a "$source_root/etc/sonic/config_db.json" "$work/data/etc/sonic/" || true
    fi
    if [[ -d "$source_root/home" ]]; then
        mkdir -p "$work/data/home"
        if declare -F copy_dir_tar >/dev/null 2>&1; then
            copy_dir_tar "$source_root/home" "$work/data/home"
        else
            ( cd "$source_root/home" && tar -cpf - . ) | ( cd "$work/data/home" && tar --numeric-owner -xpf - )
        fi
    fi
    if [[ -f "$source_root/etc/ssh/sshd_config" ]]; then
        mkdir -p "$work/data/etc/ssh"
        cp -a "$source_root/etc/ssh/sshd_config" "$work/data/etc/ssh/" || true
        if [[ -d "$source_root/etc/ssh/sshd_config.d" ]]; then
            mkdir -p "$work/data/etc/ssh/sshd_config.d"
            cp -a "$source_root/etc/ssh/sshd_config.d/." "$work/data/etc/ssh/sshd_config.d/" || true
        fi
        for key in "$source_root"/etc/ssh/ssh_host_*; do [[ -f "$key" ]] && cp -a "$key" "$work/data/etc/ssh/" || true; done
    fi
    if [[ -f "$source_root/etc/shadow" ]] && grep -q '^admin:' "$source_root/etc/shadow" 2>/dev/null; then
        awk -F: '/^admin:/{print $0}' "$source_root/etc/shadow" >"$work/meta/shadow.admin" || true
    fi
    if [[ -f "$source_root/etc/fstab" ]]; then
        mkdir -p "$work/data/etc"
        cp -a "$source_root/etc/fstab" "$work/data/etc/" || true
    fi
    if [[ -f "$source_root/etc/sonic/custom-fan/fancontrol" ]]; then
        mkdir -p "$work/data/etc/sonic/custom-fan"
        cp -a "$source_root/etc/sonic/custom-fan/fancontrol" "$work/data/etc/sonic/custom-fan/fancontrol" || true
    fi

    # Manifest
    local image_list=""
    if command -v sonic-installer >/dev/null 2>&1; then
        image_list=$(sonic-installer list 2>/dev/null || true)
    fi
    cat >"$work/manifest.json" <<EOF
{
  "created_at": "$(date -Is)",
  "host": "$(hostname 2>/dev/null || echo unknown)",
  "platform": "$platform",
  "script_version": "$SCRIPT_VERSION",
  "images": $(printf %q "$image_list" | sed 's/^"//;s/"$//;s/\\n/\\n/g' | sed 's/^/"/;s/$/"/'),
  "paths": ["/etc/sonic/config_db.json","/home","/etc/ssh","/etc/fstab","/etc/sonic/custom-fan/fancontrol"]
}
EOF

    # Pack
    (cd "$work" && tar -czf "$out" .)
    log "Backup written: $out"
}

restore_backup() {
    local in="$1" target_root="$2"
    [[ -r "$in" ]] || die "--input not readable"
    [[ -d "$target_root" ]] || die "--target-root must be a directory"

    local work
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    tar -xzf "$in" -C "$work"

    # Restore files
    if [[ -f "$work/data/etc/sonic/config_db.json" ]]; then
        mkdir -p "$target_root/etc/sonic"
        cp -a "$work/data/etc/sonic/config_db.json" "$target_root/etc/sonic/config_db.json"
    fi
    if [[ -d "$work/data/home" ]]; then
        mkdir -p "$target_root/home"
        if declare -F copy_dir_tar >/dev/null 2>&1; then
            copy_dir_tar "$work/data/home" "$target_root/home"
        else
            ( cd "$work/data/home" && tar -cpf - . ) | ( cd "$target_root/home" && tar --numeric-owner -xpf - )
        fi
    fi
    if [[ -d "$work/data/etc/ssh" ]]; then
        mkdir -p "$target_root/etc/ssh"
        cp -a "$work/data/etc/ssh/." "$target_root/etc/ssh/"
    fi
    if [[ -f "$work/data/etc/fstab" ]]; then
        mkdir -p "$target_root/etc"
        cp -a "$work/data/etc/fstab" "$target_root/etc/fstab"
    fi
    if [[ -f "$work/data/etc/sonic/custom-fan/fancontrol" ]]; then
        mkdir -p "$target_root/etc/sonic/custom-fan"
        cp -a "$work/data/etc/sonic/custom-fan/fancontrol" "$target_root/etc/sonic/custom-fan/fancontrol"
    fi
    # Shadow admin line
    if [[ -f "$work/meta/shadow.admin" ]] && [[ -f "$target_root/etc/shadow" ]]; then
        local line
        line=$(cat "$work/meta/shadow.admin")
        cp -a "$target_root/etc/shadow" "$target_root/etc/shadow.bak.$(date +%s)" || true
        if grep -qE '^admin:' "$target_root/etc/shadow"; then
            sed -i "s%^admin:[^:]*:%${line%%:*}:${line#*:}%" "$target_root/etc/shadow" || {
                sed -i "\%^admin:% d" "$target_root/etc/shadow"; echo "$line" >>"$target_root/etc/shadow"; }
        else
            echo "$line" >>"$target_root/etc/shadow"
        fi
        chmod 640 "$target_root/etc/shadow" || true
        chown root:shadow "$target_root/etc/shadow" || true
    fi

    log "Restore applied to $target_root"
}

main() {
    need_root
    local cmd=${1:-}; shift || true
    local output="" input="" target_root="" source_root=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output=${2:-}; shift ;;
            --input) input=${2:-}; shift ;;
            --target-root) target_root=${2:-}; shift ;;
            --source-root) source_root=${2:-}; shift ;;
            -h|--help) usage; exit 0 ;;
            *) log "WARN: unknown arg $1" ;;
        esac; shift
    done
    case "$cmd" in
        backup) create_backup "$output" "$source_root" ;;
        restore) restore_backup "$input" "$target_root" ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"