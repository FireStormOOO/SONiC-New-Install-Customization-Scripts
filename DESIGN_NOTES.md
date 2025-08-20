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
- No-handholding mode: `--no-handholding` skips non-essential confirmations. Stale image checks (>4h and >72h) become non-blocking when enabled.
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

### Overlay rationale and constraints
- Why overlays: SONiC images typically boot a squashfs rootfs with an overlay upper/work under `/host/image-<tag>/{rw,work}`. We need a safe way to prepare “next boot” state without disturbing the live system. Writing directly into the live merged root (`/`) is unsafe; writing into the image dir depends on the lower layout (squashfs vs fsroot). Preparing a second overlay at `/newroot` abstracts those differences and makes all customizations uniform.
- Same-image limitation: SONiC won’t install the exact same image tag to both slots. When operators want a clean slate on the same squashfs, we prepare a fresh overlay and “make-before-break” by renaming overlay dirs (`rw/work` ↔ `rw-next/work-next`) while live. The kernel keeps references to the old dirs until reboot, so the swap only affects the next boot.
- Activation timing: We avoid shutdown-time hooks because late shutdown may lack tools/paths after unmount. Live renames are deterministic and simple.
- Lowerdir detection: Prefer `fs.squashfs` when present for read-only lower. Some builds use `fsroot/` instead. If neither exists, we fail fast rather than risk corrupting the image.
- Boot entries: We do not attempt to fabricate new GRUB entries pointing at the same squashfs; that would couple us to `sonic-installer` internals. The overlay swap is simpler and robust.
- pmon/fancontrol: Platform thermal services can overwrite fan curves at boot. We install a persistent override unit that copies our curve from `/etc/sonic/custom-fan/fancontrol` to the platform path and restarts `pmon` once each boot.
- Brew: Homebrew bootstrap assumes network and `curl`. It is installed as a guarded oneshot; absence of `curl` is non-fatal.
- /newroot guardrails: Any command that assumes `/newroot` exists checks for a mounted overlay and emits a clear hint to run `sonic-overlay.sh prepare ... --mount` when missing.
- Heuristics: Newest image detection uses mtime of `rw/` (preferred) or `fsroot/`. Recency check warns >4h and strongly warns >72h to protect against unintended edits to older images.
- Space & rsync: We estimate headroom for copying `/home` and prefer rsync with numeric-ids/xattrs; scripts fall back to `cp -a` if rsync is absent.

### Future Enhancements
- Optional `--target <image>` to pick a specific offline image.
- Post-boot health check unit to verify fan curve application and service states.
- Additional SSH hardening options or templated policies.
- Chrooted operations if future SONiC releases require it for certain tools.

### File Map
- `README.md`: Overview and usage
- `DEVELOPER_NOTES.md`: Developer-focused details and flags
- `DESIGN_NOTES.md`: Design goals, decisions, and future enhancements
- `sonic-deploy.sh`: Orchestrator entrypoint
- `sonic-offline-customize.sh`: Main customization (overlay-based)
- `sonic-overlay.sh`: Overlay prepare/activate
- `sonic-backup.sh`: Backup/restore
- `sonic-offline-validate.sh`: Pre-flight validation