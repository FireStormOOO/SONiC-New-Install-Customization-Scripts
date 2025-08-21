## SONiC Upgrade Helper

### Overview
These scripts exist to simplify upgrades to SONiC switches that aren't centrally managed, transferring a reasonable amount of user state and basic configuration across to the new image, and enabling save/restore of the same. Built with version 202411 in mind but most of this should be version agnostic. Fan curve stuff will be fairly specific to a given deployment (e.g. author flipped all the fans around to reverse airflow direction and then reduced noise) but the general approach should apply. Homebrew installed by default to have a little more choice of admin tools. Some assumptions are geared to Seastone DX010 switches, defaults may not be reasonable if you're using something else; by default assumes a flash drive is present for upgrades and mounted at /media/flashdrive and is left available (DX010 has only a 16GB internal flash).

**Status:** Beta quality, tested on a narrow slice of hardware. Use with appropriate caution. Flaws in this tool's copy feature may also exist in the backup/restore; manually backup anything you can't afford to lose.

**Architecture:** Unified interface with hybrid bash/Python design. Bash handles system integration and user interaction, Python manages complex state operations and data validation.

### Architecture

**Hybrid Design:**
- **Bash Layer**: CLI interface, system integration, root privileges, user interaction
- **Python Core**: State management, data validation, complex operations
- **Clean Abstractions**: State components defined declaratively, source/destination agnostic

**Files:**
- `sonic-upgrade-helper`: Main unified interface (all common workflows)
- `sonic-overlay.sh`: Low-level overlay operations (power users)
- `sonic-offline-validate.sh`: Debug/testing validation
- `lib/sonic_state.py`: Python state management core
- `lib/sonic-common.sh`: Shared bash utilities

### State Components Managed

The system manages these state components consistently across all operations:
- **SONiC Configuration**: `/etc/sonic/config_db.json`
- **User Data**: `/home/*` (home directories and SSH keys)
- **SSH Infrastructure**: `/etc/ssh/*` (server config, host keys)
- **System Mounts**: `/etc/fstab` with auto-mount for flashdrive
- **Fan Control**: `/etc/sonic/custom-fan/fancontrol` (persistent custom curves)
- **Admin Authentication**: `/etc/shadow` (admin user password hash)

### Usage

Run from the active image as root. Common workflows:

Save current system state:
```bash
sudo sonic-upgrade-helper save --output /media/flashdrive/my-setup.tar.gz
```

Install new image with settings restoration:
```bash
sudo sonic-upgrade-helper install /media/flashdrive/sonic-202411.bin --restore /media/flashdrive/my-setup.tar.gz --activate
```

Re-customize current image (same-squashfs fresh overlay) after config changes:
```bash
sudo sonic-upgrade-helper reinstall --activate
```

Customize specific image:
```bash
sudo sonic-upgrade-helper customize --image /host/image-sonic-202411 --activate
```

**Power User Workflows:**

Manual overlay management:
```bash
sonic-upgrade-helper overlay prepare --image /host/image-xyz --mount
sonic-upgrade-helper state migrate --source / --target /newroot
sonic-upgrade-helper overlay activate --image /host/image-xyz --name custom
```

Direct state operations:
```bash
sonic-upgrade-helper state backup --output backup.tar.gz
sonic-upgrade-helper state restore --input backup.tar.gz --target /newroot
sonic-upgrade-helper state validate  # Debug/testing
```

**Common Options:**
- `--dry-run` (`-n`): Show planned actions without making changes
- `--quiet` (`-q`): Skip non-essential confirmations
- `--no-brew`, `--no-fancontrol`: Skip those customizations
- `--help` (`-h`): Show help for any command

Advanced overlay usage and development details are documented in `DEVELOPER_NOTES.md`.

### Notes

- The customize script is versioned and logs its version and completion marker into the offline image at `var/log/sonic-offline-customize.log`.
- Custom fan curve file expected at `/media/flashdrive/fancontrol-custom4.bak`. It is persisted into the offline image at `etc/sonic/custom-fan/fancontrol`, and restored on every boot by `fancontrol-override.service`.

### Customizations Applied

- **Admin Password**: Preserves existing admin password hash
- **SSH Configuration**: Transfers server config, host keys, and user SSH keys  
- **Network Configuration**: Transfers `config_db.json`
- **User Data**: Preserves all home directories
- **Storage**: Updates `fstab` with flashdrive auto-mount
- **Fan Control**: Applies custom fan curves on every boot
- **Development Tools**: Installs Homebrew on first boot (optional)

### Environment Assumptions

- **Platform**: Tested on Seastone DX010, should work on other x86_64 SONiC platforms
- **Storage**: Flash drive mounted at `/media/flashdrive` for backups and images
- **Network**: Internet access required for Homebrew installation (optional)
- **Tools**: Standard POSIX tools (tar, date, hostname, blkid, findmnt, stat, awk, sed, grep)

### Documentation

- [Design Notes](DESIGN_NOTES.md) - Architecture and design decisions
- [Developer Notes](DEVELOPER_NOTES.md) - Development and testing guide

### License

GPL-3.0-only (see `LICENSE`).