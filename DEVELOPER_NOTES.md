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

### Development Practices

**Git Workflow:**

Commit Message Format - Follow [Conventional Commits v1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):
```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Common Types:
- `feat`: New feature (MINOR version bump)
- `fix`: Bug fix (PATCH version bump) 
- `feat!` or `fix!`: Breaking change (MAJOR version bump)
- `refactor`: Code refactoring without functional changes
- `docs`: Documentation changes
- `test`: Adding or updating tests

Breaking Changes Example:
```
feat!: add new state component handling

BREAKING CHANGE: Modified state component interface. Migration: update component definitions to use new format.
```

**Merge Strategy**: Squash merges preferred
- Keeps clean linear history
- Single commit per feature/fix
- Use conventional commit format for squash merge message

**Semantic Versioning**: `MAJOR.MINOR.PATCH`
- **MAJOR**: Breaking changes (API changes, removed functionality)
- **MINOR**: New features (backward compatible)  
- **PATCH**: Bug fixes (backward compatible)

**Code Standards:**

Bash:
- Use `set -euo pipefail` at top of all scripts
- Source `lib/sonic-common.sh` for shared functions
- Use `dry` helpers for DRY-RUN support
- Validate arguments early with clear error messages

Python:
- Follow PEP 8 style guidelines
- Use type hints for function signatures
- Implement proper exception handling
- Add docstrings for classes and methods

**Testing Workflow:**
- Test with `--dry-run` first
- Validate with `sonic-upgrade-helper validate`
- Verify Python module: `python3 -m py_compile lib/sonic_state.py`
- Run environment validation: `sudo sonic-offline-validate.sh`

### Future Improvements
- Enhanced validation and integrity checking
- Incremental backup support
- State component versioning for schema changes
- Comprehensive automated test suite

