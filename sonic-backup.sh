#!/usr/bin/env bash

set -euo pipefail

# SONiC backup/restore helper
# Creates a tarball with key configuration and an accompanying manifest

# source common helpers (required)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/sonic-common.sh"

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

# prefer library detect_platform
declare -F detect_platform >/dev/null 2>&1 || detect_platform() { echo unknown; }

create_backup() {
    local out="$1" source_root="${2:-/}"
    [[ -n "$out" ]] || die "--output is required"
    [[ -d "$source_root" ]] || die "--source-root not a directory"

    # Use Python state management core
    local python_cmd=("python3" "$SCRIPT_DIR/lib/sonic_state.py" "backup" "--source" "$source_root" "--output" "$out")
    [[ ${DRY_RUN:-0} -eq 1 ]] && python_cmd+=(--dry-run)
    
    if "${python_cmd[@]}"; then
        log "Backup completed: $out"
    else
        die "Backup failed"
    fi
}

restore_backup() {
    local in="$1" target_root="$2"
    [[ -r "$in" ]] || die "--input not readable"
    [[ -d "$target_root" ]] || die "--target-root must be a directory"

    # Use Python state management core
    local python_cmd=("python3" "$SCRIPT_DIR/lib/sonic_state.py" "restore" "--input" "$in" "--target" "$target_root")
    [[ ${DRY_RUN:-0} -eq 1 ]] && python_cmd+=(--dry-run)
    
    if "${python_cmd[@]}"; then
        log "Restore completed to $target_root"
    else
        die "Restore failed"
    fi
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