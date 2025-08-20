## SONiC Offline Customization - Design Notes

### Goals
- Prepare the offline SONiC image (A/B model) with site-specific configuration before reboot, minimizing downtime.
- Ensure idempotency, predictable behavior, and safe fallbacks.
- Provide a validator to detect environmental issues before making changes.

### Target Environment
- SONiC 202411 on Seastone DX010: `x86_64-cel_seastone-r0`.
- Offline images live under `/host/image-*`; effective root is `/host/image-*/fsroot` when present.
- Flash media mounted at `/media/flashdrive` provides custom assets.

### Key Decisions
- Offline root resolution: prefer `/host/image-*/fsroot` if it exists; otherwise use `/host/image-*`.
- Recentness heuristic: warn if modified >4h, soft-warn >72h. Uses `fsroot` mtime when available.
- Idempotency marker: use a log file in the offline image (`/var/log/sonic-offline-customize.log`) and only treat customization as complete when the log contains `CUSTOMIZATION_COMPLETED` with version.
- Versioned runs: `SCRIPT_VERSION` logged at the start of execution and recorded on completion.
- Dry-run support: `--dry-run` prints planned actions, writes nothing, but still prompts.
- Platform detection: `sonic-cfggen -H -v DEVICE_METADATA.localhost.platform` with fallback to known platform string.
- SSH migration: copy `sshd_config`, optional `sshd_config.d`, host keys, and user `.ssh` directories.
- Password migration: copy the hash line for `admin` (or operator-provided user) from current `/etc/shadow` into the offline image's `/etc/shadow` with backup.
- fstab propagation: copy current `/etc/fstab` into offline image and append an entry for the current flashdrive UUID with `x-systemd.automount`.
- Brew bootstrap: install a first-boot oneshot service `brew-bootstrap.service` that runs the official Homebrew install if `curl` is present, guarded by a state file.
- Fancontrol persistence: store custom curve at `etc/sonic/custom-fan/fancontrol` and install `fancontrol-override.service` to restore it into `usr/share/sonic/device/<platform>/fancontrol` and restart `pmon` on every boot. If a `fancontrol.service` is provided on the flashdrive, it is also installed and enabled.
- Cutover UX: prompt to set next boot (`sonic-installer set-next-boot <image>`) and optionally reboot now.

### Validation Approach
`sonic-offline-validate.sh` performs non-destructive checks:
- Required binaries present (e.g., `sonic-installer`, `rsync`, `blkid`).
- SONiC version and platform detection.
- Newest offline image discovery and `fsroot` resolution.
- Recentness of the target image.
- Flashdrive mount and UUID; expected asset presence.
- Offline root layout (presence of `etc/`, `etc/shadow`, platform dir) and writability probe.
- Space estimation for copying `/home` (simple headroom check).
- Admin user presence and `/etc/shadow` readability.
- Advisory diff between running config and saved `/etc/sonic/config_db.json` (whitespace-insensitive; list order may differ).
- Presence of `pmon.service` on the current system for expectations.

### Edge Cases and Safeguards
- Missing tools: warnings logged; some steps may be skipped.
- Missing assets (fancontrol settings): proceed without failing; override unit will log a message and skip.
- `show runningconfiguration` ordering differences: flagged as advisory only.
- Permission adjustments: shadow file writes guarded; backups created.
- Symlink enablement for services done by creating `multi-user.target.wants` links within the offline image.

### Future Enhancements
- Optional `--target <image>` to pick a specific offline image.
- Post-boot health check unit to verify fan curve application and service states.
- Additional SSH hardening options or templated policies.
- Chrooted operations if future SONiC releases require it for certain tools.

### File Map
- `sonic-offline-customize.sh`: main customization script (idempotent; supports `--dry-run`).
- `sonic-offline-validate.sh`: pre-flight validation script (non-destructive).

