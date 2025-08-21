## Developer Notes

### Architecture Overview

**Hybrid Design**: Bash for system integration, Python for state management
- **`sonic-upgrade-helper`**: Main unified interface - all common workflows consolidated
- **`lib/sonic_state.py`**: Python state management core with clean abstractions
- **`lib/sonic-common.sh`**: Shared bash utilities and helper functions
- **`sonic-overlay.sh`**: Low-level overlay operations (kept for power users)
- **`sonic-offline-validate.sh`**: Debug/testing validation tool

### Core Components

**Python State Management (`lib/sonic_state.py`)**:
- **StateComponent**: Declarative definitions of system state (config, SSH, users, etc.)
- **StateAdapter**: Abstract interface for sources/destinations (filesystem, backup files)
- **StateManager**: Core operations (backup, restore, migrate, validate) with proper error handling
- **CLI Interface**: Can be called directly for power users

**Bash Integration (`sonic-upgrade-helper`)**:
- **Workflow Orchestration**: install, reinstall, customize, save workflows
- **User Interaction**: Prompts, confirmations, next boot management
- **System Integration**: sonic-installer calls, overlay preparation, root privilege handling
- **Overlay Management**: Delegates to `sonic-overlay.sh` for low-level operations

**Overlay Manager (`sonic-overlay.sh`)**:
- `prepare`: creates `rw-next-<name>/{upper,work}` under an image dir and mounts overlay at `/newroot`
- `unmount`: cleanly unmount `/newroot` and squashfs lower if mounted  
- `activate`: live-rename overlay dirs for safe activation on next boot

**State Components Managed**:
- SONiC configuration (`/etc/sonic/config_db.json`)
- User data and SSH keys (`/home`, `/etc/ssh`)
- System mounts (`/etc/fstab`)
- Fan control settings (`/etc/sonic/custom-fan/fancontrol`)
- Admin authentication (`/etc/shadow`)

### Key behaviors and assumptions
- Always customize an overlay mounted at `/newroot`; upstream image can be the same image or different — the customize steps don’t care.
- Lowerdir resolution prefers `fs.squashfs` (`fsroot` as fallback). We fail-fast if neither exists.
- Live activation uses directory renames only; the running kernel still holds the old upper/work handles until reboot. This safely switches which upper/work will be used on next boot.
- **Simplified recency checks**: Only warns for explicitly specified old images (>7 days), no more complex thresholds
- **Idempotency marker**: `/var/log/sonic-offline-customize.log` inside the target root must contain `CUSTOMIZATION_COMPLETED` and version
- **Fancontrol persistence**: Config stored at `/etc/sonic/custom-fan/fancontrol`; `fancontrol-override.service` restores it to the platform dir and restarts `pmon` on every boot
- **Brew bootstrap**: Oneshot unit runs Homebrew's installer on first boot if `curl` is present

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

