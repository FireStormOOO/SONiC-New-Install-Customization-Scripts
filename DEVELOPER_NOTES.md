## Developer Notes

### What’s in the repo now
- `sonic-offline-validate.sh`: Read-only validation of environment (binaries, image layout, recency, flashdrive, space, users/shadow, pmon, running vs saved config advisory).
- `sonic-overlay.sh`: Overlay manager
  - `prepare`: creates `rw-next-<name>/{upper,work}` under an image dir and mounts an overlay at `/newroot` with lowerdir resolved from `fs.squashfs` or `fsroot`.
  - `unmount`: cleanly unmount `/newroot` and the squashfs lower if mounted.
  - `activate`: live-rename overlay dirs: `rw`→`rw-old-<ts>`, `work`→`work-old-<ts>`, and `rw-next-<name>`→`rw`, `work-next-<name>`→`work`, then prunes old sets (retain N).
- `sonic-backup.sh`: Backup/restore helper
  - `backup`: tar.gz with `manifest.json` and key data (`config_db.json`, `/home`, SSH configs/keys, admin shadow line, `fstab`, custom fancontrol).
  - `restore`: applies to a target root (e.g., `/newroot`) idempotently.
- `sonic-offline-customize.sh`: Main customize script (now overlay-based)
  - Prepares `/newroot` via `sonic-overlay.sh prepare` and applies all customizations against `/newroot`.
  - Installs a brew first-boot unit and a persistent fancontrol override unit by default (opt-out flags available).
- `sonic-deploy.sh`: Orchestrator for common flows
  - `backup`: wraps `sonic-backup.sh backup`
  - `restore`: prepares overlay then runs `sonic-backup.sh restore` into `/newroot` (or custom target root)
  - `install`: runs `sonic-installer install -y <bin>` then customizes overlay; auto-detects same-image vs new-image
  - `reinstall`: same-image fresh overlay + customize + activation, no bin required
- `DESIGN_NOTES.md`: High-level goals and decisions.
- `README.md`: Usage and quick-start, including overlay flow.

### Key behaviors and assumptions
- Always customize an overlay mounted at `/newroot`; upstream image can be the same image or different — the customize steps don’t care.
- Lowerdir resolution prefers `fs.squashfs` (`fsroot` as fallback). We fail-fast if neither exists.
- Live activation uses directory renames only; the running kernel still holds the old upper/work handles until reboot. This safely switches which upper/work will be used on next boot.
- Recency checks: warn >4h, strong warn >72h with guidance to run `sonic-installer install` first; confirmations respect `--no-handholding`.
- Idempotency marker: `/var/log/sonic-offline-customize.log` inside the target root must contain `CUSTOMIZATION_COMPLETED` and version.
- Fancontrol persistence: config stored at `/etc/sonic/custom-fan/fancontrol`; `fancontrol-override.service` restores it to the platform dir and restarts `pmon` on every boot.
- Brew bootstrap: oneshot unit runs Homebrew’s installer on first boot if `curl` is present.

### Flags (summary)
- `sonic-offline-customize.sh`
  - `--dry-run`, `--no-handholding`/`--quiet`
  - `--image-dir`, `--rw-name`, `--lower auto|fs|dir`
  - `--activate`, `--retain N`
  - `--no-brew`, `--no-fancontrol`
- `sonic-overlay.sh`
  - `prepare --image-dir DIR [--lower auto|fs|dir] [--rw-name NAME] [--mount]`
  - `activate --image-dir DIR --rw-name NAME [--retain N]`
  - `unmount`
- `sonic-backup.sh`
  - `backup --output FILE.tgz [--source-root /]`
  - `restore --input FILE.tgz --target-root /newroot`
- `sonic-deploy.sh`
  - `backup --output FILE.tgz [--source-root /]`
  - `restore [--image-dir DIR] [--rw-name NAME] [--lower auto|fs|dir] --input FILE.tgz [--target-root /newroot]`
  - `install --bin path.bin [--rw-name NAME] [--lower auto|fs|dir] [--no-brew] [--no-fancontrol] [--no-handholding|--quiet] [--dry-run]`
  - `reinstall [--rw-name NAME] [--lower auto|fs|dir] [--no-brew] [--no-fancontrol] [--no-handholding|--quiet] [--dry-run]`

### Same-image vs different-image
- Different-image: After customizing `/newroot`, normal next-boot flow to the new image works; ensure that `rw-next` is renamed to `rw` before reboot if the image expects specific dir names.
- Same-image: Prefer live-activation (rename overlay dirs) and keep last N old overlays for rollback (default N=2). You can optionally set next boot to the current image.

### Logging and safety
- Versioned logging at start; completion marker appended on success.
- Fail-fast when `/newroot` isn’t mounted after prepare, or when required paths are missing, with a consistent hint to run overlay prepare.
- Dry-run echoes all file operations and overlay actions.

### Future improvements
- Orchestrator wrapper (e.g., `sonic-deploy.sh`) to chain: validate → (optional) sonic-installer install → overlay prepare → (optional) backup/restore → customize → (optional) activate → set-next-boot → reboot.
- Read target image name reliably by inspecting `sonic-installer` logic or metadata to decide “same image” vs “different image” automatically.
- Unified logging and a consistent artifact directory on the flashdrive.

