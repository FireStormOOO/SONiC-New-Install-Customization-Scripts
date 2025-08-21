## SONiC New Install Customization Scripts

### Overview
Scripts to simplify upgrades on SONiC switches without central management. They transfer a reasonable set of user state and base configuration to the next boot image, and support saving/restoring the same. Built with SONiC 202411 in mind, but most logic is version-agnostic. Fan curve tweaks are deployment-specific (e.g., reversed airflow and noise reduction), but the pattern is reusable. Homebrew is installed by default to provide more admin tooling.

Status: alpha quality, minimally tested. Use with care and review the outputs.

### Scripts
- `sonic-deploy.sh`: orchestrator for common flows (backup, restore to overlay, install/reinstall + customize).
- `sonic-offline-customize.sh`: overlay-based customization against `/newroot` (brew + fancontrol enabled by default).
- `sonic-offline-validate.sh`: validates environment assumptions.
- `sonic-backup.sh`: backup/restore key configuration.
- `sonic-overlay.sh`: prepare and activate overlays (advanced).

What we transfer/customize (succinct):
- Existing admin password (hash) for the target root
- SSH server config and host keys; user SSH keys
- `config_db.json` and user home directories (`/home`)
- `fstab` with auto-mount entry for the flashdrive
- Fan curve: persistent custom curve applied on each boot via override
- Homebrew: first-boot installer oneshot (network + `curl` required)

### Usage
Run from the active image as root. Orchestrated flows (wraps SONiC `sonic-installer` for installs; also supports in-place reinstall):
- Backup running system:
```bash
sudo /workspace/sonic-deploy.sh backup --output /media/flashdrive/sonic-backup.tgz
```
- Restore backup into overlay on target image (auto-detect image):
```bash
sudo /workspace/sonic-deploy.sh restore --input /media/flashdrive/sonic-backup.tgz
```
- Install new image from bin and customize (handles same-image vs new-image):
```bash
sudo /workspace/sonic-deploy.sh install --bin /media/flashdrive/sonic-broadcom.bin
```
- Reinstall the current image (same-squashfs fresh overlay) and customize:
```bash
sudo /workspace/sonic-deploy.sh reinstall
```

Common flags:
- `--dry-run` (`-n`): print planned actions without modifying files
- `--no-handholding` (`-q`, `--quiet`): skip non-essential confirmations
- `--no-brew`, `--no-fancontrol`: skip those customizations

Advanced overlay usage is documented in `DEVELOPER_NOTES.md`.

### Notes
- The customize script is versioned and logs its version and completion marker into the offline image at `var/log/sonic-offline-customize.log`.
- Custom fan curve file expected at `/media/flashdrive/fancontrol-custom4.bak`. It is persisted into the offline image at `etc/sonic/custom-fan/fancontrol`, and restored on every boot by `fancontrol-override.service`.

License: GPL-3.0-only (see `LICENSE`).

See `DESIGN_NOTES.md` for design rationale and constraints, and `DEVELOPER_NOTES.md` for implementation details.

