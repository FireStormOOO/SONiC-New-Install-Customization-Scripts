## SONiC New Install Customization Scripts

### Overview
Tools to customize the offline SONiC image (A/B model) before reboot to minimize downtime. Targeted for SONiC 202411 on Seastone DX010 (`x86_64-cel_seastone-r0`).

### Scripts
- `sonic-offline-validate.sh` (non-destructive): validates environment assumptions (binaries, platform, newest image and fsroot, recentness, flashdrive UUID/assets, offline layout, space for `/home`, admin/shadow, running vs saved config advisory, `pmon` present).
- `sonic-offline-customize.sh` (idempotent): copies config, users, SSH settings, admin password hash, updates fstab, installs fancontrol override, and adds a first-boot Homebrew bootstrap service. Prompts to set next boot and to reboot.

### Usage
Copy to flashdrive and run from the active image as root:

```bash
sudo bash /media/flashdrive/sonic-offline-validate.sh
sudo bash /media/flashdrive/sonic-offline-customize.sh --dry-run
sudo bash /media/flashdrive/sonic-offline-customize.sh
```

Flags:
- `--dry-run` (`-n`): print planned actions without modifying the offline image
- `--no-handholding` (`-q`): skip non-essential confirmations (warnings still logged)

### Notes
- The customize script is versioned and logs its version and completion marker into the offline image at `var/log/sonic-offline-customize.log`.
- Custom fan curve file expected at `/media/flashdrive/fancontrol-custom4.bak`. It is persisted into the offline image at `etc/sonic/custom-fan/fancontrol`, and restored on every boot by `fancontrol-override.service`.

See `DESIGN_NOTES.md` for design decisions and details.

