## SONiC New Install Customization Scripts

### Overview
Tools to customize the offline SONiC image (A/B model) before reboot to minimize downtime. Targeted for SONiC 202411 on Seastone DX010 (`x86_64-cel_seastone-r0`). Offline image roots are auto-detected; if present, the writable overlay `rw/` is used; otherwise `fsroot/` or the image dir.

### Scripts
- `sonic-deploy.sh`: orchestrator for common flows (backup, restore to overlay, install/reinstall + customize).
- `sonic-offline-customize.sh`: overlay-based customization against `/newroot` (brew + fancontrol enabled by default).
- `sonic-offline-validate.sh`: validates environment assumptions.
- `sonic-backup.sh`: backup/restore key configuration.
- `sonic-overlay.sh`: prepare and activate overlays (advanced).

### Usage
Run from the active image as root. Orchestrated flows:
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

See `DESIGN_NOTES.md` for design decisions and details.

