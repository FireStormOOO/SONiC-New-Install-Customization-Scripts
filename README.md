## SONiC New Install Customization Scripts

### Overview
Tools to customize the offline SONiC image (A/B model) before reboot to minimize downtime. Targeted for SONiC 202411 on Seastone DX010 (`x86_64-cel_seastone-r0`). Offline image roots are auto-detected; if present, the writable overlay `rw/` is used; otherwise `fsroot/` or the image dir.

### Scripts
- `sonic-offline-validate.sh` (non-destructive): validates environment assumptions (binaries, platform, newest image and fsroot, recentness, flashdrive UUID/assets, offline layout, space for `/home`, admin/shadow, running vs saved config advisory, `pmon` present).
- `sonic-offline-customize.sh` (idempotent): copies config, users, SSH settings, admin password hash, updates fstab, installs fancontrol override, and adds a first-boot Homebrew bootstrap service. Prompts to set next boot and to reboot.
- `sonic-backup.sh`: backup/restore of key configuration to a tarball with a manifest.
- `sonic-overlay.sh`: manage overlays for a target image dir; prepare `/newroot`, and activate by live-renaming overlay dirs.
- `sonic-deploy.sh`: orchestrator to run common flows (backup, restore to overlay, install+customize).

### Usage
Copy to flashdrive and run from the active image as root:

```bash
sudo bash /media/flashdrive/sonic-offline-validate.sh
sudo bash /media/flashdrive/sonic-offline-customize.sh --dry-run
sudo bash /media/flashdrive/sonic-offline-customize.sh
```

Orchestrated flows:
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

Flags:
- `--dry-run` (`-n`): print planned actions without modifying the offline image
- `--no-handholding` (`-q`): skip non-essential confirmations (warnings still logged)
- `--no-brew`: skip installing the Homebrew first-boot service
- `--no-fancontrol`: skip installing fancontrol settings and services
Overlay flow (advanced):
- Prepare a new overlay against a chosen image dir and mount at `/newroot`:
```bash
sudo /workspace/sonic-overlay.sh prepare --image-dir /host/image-<tag> --lower auto --rw-name test --mount
```
- Backup current system and restore into `/newroot`:
```bash
sudo /workspace/sonic-backup.sh backup --output /media/flashdrive/sonic-backup.tgz
sudo /workspace/sonic-backup.sh restore --input /media/flashdrive/sonic-backup.tgz --target-root /newroot
```
- Apply customizations (reuse sonic-offline-customize against /newroot in future integration), unmount if desired, then activate by live-renaming:
```bash
sudo /workspace/sonic-overlay.sh unmount
sudo /workspace/sonic-overlay.sh activate --image-dir /host/image-<tag> --rw-name test --retain 2
```
- `--no-brew`: skip installing the Homebrew first-boot service
- `--no-fancontrol`: skip installing fancontrol settings and services

### Notes
- The customize script is versioned and logs its version and completion marker into the offline image at `var/log/sonic-offline-customize.log`.
- Custom fan curve file expected at `/media/flashdrive/fancontrol-custom4.bak`. It is persisted into the offline image at `etc/sonic/custom-fan/fancontrol`, and restored on every boot by `fancontrol-override.service`.

See `DESIGN_NOTES.md` for design decisions and details.

