## SONiC Upgrade Helper

### Overview
Unified interface for SONiC image management with hybrid bash/Python architecture. Streamlines backup, installation, customization, and restoration workflows for SONiC switches that aren't centrally managed.

**Key Features:**
- Single command interface for all common workflows
- Hybrid architecture: Bash for system integration, Python for state management
- Clean separation of concerns: What (state) vs Where (source/dest) vs How (operations)
- Built for SONiC 202411 but designed to be version-agnostic
- Preserves user state and configuration across upgrades

**Status:** Production-ready consolidated version. Extensively refactored from original alpha scripts.

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

**Common Workflows:**

Save current system state:
```bash
sudo sonic-upgrade-helper save --output my-setup.tar.gz
```

Install new image with settings restoration:
```bash
sudo sonic-upgrade-helper install sonic-image-202411.bin --restore my-setup.tar.gz --activate
```

Re-customize current image (after config changes):
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

**Global Options:**
- `--dry-run` (`-n`): Show planned actions without making changes
- `--quiet` (`-q`): Minimize output, skip confirmations
- `--help` (`-h`): Show help for any command

### Complete Upgrade Example

```bash
# 1. Save current setup
sudo sonic-upgrade-helper save --output /media/flashdrive/backup.tar.gz

# 2. Install new image with restoration
sudo sonic-upgrade-helper install /media/flashdrive/sonic-202411.bin \
    --restore /media/flashdrive/backup.tar.gz --activate

# 3. Reboot to new image (when prompted)
```

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