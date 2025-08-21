## SONiC New Install Customization Scripts

### Overview
These scripts exists to simplify upgrades to SONiC switches that aren't centrally managed, transferring a reasonable amount of user state and basic configuration across to the new image, and enabling save/restore of the same.  Built with version 202411 in mind but most of this should be version agnostic.  Fan curve stuff will be fairly specific to a given deployment (e.g. author flipped all the fans around to reverse airflow direction and then reduced noise) but the general approach should apply.  Homebrew installed by default to have a little more choice of admin tools.  Some assumptions are geared to Seastone DX010 switches, defaults may not be reasonable if you're using somethning else; by default assumes a flash drive is present for upgrades and mounted at /media/flashdrive and is left available (DX010 has only a 16GB internal flash).

Status: alpha quality, minimally tested on a narrow slice of hardware. Use with care, no warranty, etc.  Flaws in this tool's copy feature may also existing in the backup/restore; manually backup anything you can't afford to lose.

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

