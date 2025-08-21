#!/usr/bin/env python3
"""
SONiC State Management Core

Provides clean abstractions for managing SONiC system state independent of
source and destination. Handles backup, restore, and migration operations.
"""

import os
import json
import shutil
import tarfile
import tempfile
import logging
import subprocess
from pathlib import Path
from typing import Dict, Any, Optional, Union
from dataclasses import dataclass
from abc import ABC, abstractmethod

# Configure logging
logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(message)s', 
                   datefmt='%Y-%m-%d %H:%M:%S')
logger = logging.getLogger(__name__)

@dataclass
class StateComponent:
    """Defines a system state component"""
    name: str
    path: str
    component_type: str  # 'file', 'directory', 'user_data'
    required: bool = True
    preserve_permissions: bool = True
    special_handler: Optional[str] = None

# Define all SONiC state components
SONIC_STATE_COMPONENTS = {
    'sonic_config': StateComponent(
        name='sonic_config',
        path='/etc/sonic/config_db.json',
        component_type='file'
    ),
    'user_data': StateComponent(
        name='user_data', 
        path='/home',
        component_type='directory',
        special_handler='home_directories'
    ),
    'ssh_infrastructure': StateComponent(
        name='ssh_infrastructure',
        path='/etc/ssh',
        component_type='directory',
        special_handler='ssh_config'
    ),
    'system_mounts': StateComponent(
        name='system_mounts',
        path='/etc/fstab',
        component_type='file'
    ),
    'fan_control': StateComponent(
        name='fan_control',
        path='/etc/sonic/custom-fan/fancontrol',
        component_type='file',
        required=False
    ),
    'admin_auth': StateComponent(
        name='admin_auth',
        path='/etc/shadow',
        component_type='file',
        special_handler='admin_shadow'
    )
}

class StateAdapter(ABC):
    """Abstract base for state source/destination adapters"""
    
    @abstractmethod
    def read_file(self, path: str) -> Optional[bytes]:
        pass
    
    @abstractmethod
    def write_file(self, path: str, data: bytes, mode: Optional[int] = None) -> None:
        pass
    
    @abstractmethod
    def read_directory(self, path: str) -> Optional[bytes]:
        pass
    
    @abstractmethod
    def write_directory(self, path: str, data: bytes) -> None:
        pass
    
    @abstractmethod
    def exists(self, path: str) -> bool:
        pass

class FilesystemAdapter(StateAdapter):
    """Adapter for filesystem-based sources/destinations"""
    
    def __init__(self, root_path: str = "/", dry_run: bool = False):
        self.root_path = Path(root_path)
        self.dry_run = dry_run
    
    def _full_path(self, path: str) -> Path:
        return self.root_path / path.lstrip('/')
    
    def exists(self, path: str) -> bool:
        return self._full_path(path).exists()
    
    def read_file(self, path: str) -> Optional[bytes]:
        full_path = self._full_path(path)
        if not full_path.exists():
            return None
        try:
            return full_path.read_bytes()
        except Exception as e:
            logger.warning(f"Failed to read {full_path}: {e}")
            return None
    
    def write_file(self, path: str, data: bytes, mode: Optional[int] = None) -> None:
        full_path = self._full_path(path)
        if self.dry_run:
            logger.info(f"DRY-RUN: write {len(data)} bytes to {full_path}")
            return
        
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_bytes(data)
        if mode is not None:
            full_path.chmod(mode)
    
    def read_directory(self, path: str) -> Optional[bytes]:
        """Read directory as tar archive"""
        full_path = self._full_path(path)
        if not full_path.exists():
            return None
        
        try:
            with tempfile.NamedTemporaryFile() as tmp:
                with tarfile.open(tmp.name, 'w') as tar:
                    tar.add(full_path, arcname='.')
                return Path(tmp.name).read_bytes()
        except Exception as e:
            logger.warning(f"Failed to archive {full_path}: {e}")
            return None
    
    def write_directory(self, path: str, data: bytes) -> None:
        """Write directory from tar archive"""
        full_path = self._full_path(path)
        if self.dry_run:
            logger.info(f"DRY-RUN: extract {len(data)} bytes to {full_path}")
            return
        
        full_path.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile() as tmp:
            Path(tmp.name).write_bytes(data)
            with tarfile.open(tmp.name, 'r') as tar:
                tar.extractall(full_path, numeric_owner=True)

class BackupAdapter(StateAdapter):
    """Adapter for tar.gz backup files"""
    
    def __init__(self, backup_path: str, mode: str = 'r', dry_run: bool = False):
        self.backup_path = Path(backup_path)
        self.mode = mode
        self.dry_run = dry_run
        self._data = {}  # Cache for write mode
        self._metadata = {}
        
        if mode == 'r' and self.backup_path.exists():
            self._load_backup()
    
    def _load_backup(self):
        """Load existing backup data"""
        try:
            with tarfile.open(self.backup_path, 'r:gz') as tar:
                # Load manifest
                if 'manifest.json' in tar.getnames():
                    manifest_data = tar.extractfile('manifest.json').read()
                    self._metadata = json.loads(manifest_data.decode())
                
                # Load data files
                for member in tar.getmembers():
                    if member.name.startswith('data/') and member.isfile():
                        path = member.name[5:]  # Remove 'data/' prefix
                        self._data[path] = tar.extractfile(member).read()
        except Exception as e:
            logger.error(f"Failed to load backup {self.backup_path}: {e}")
    
    def save_backup(self):
        """Save backup with all collected data"""
        if self.dry_run:
            logger.info(f"DRY-RUN: save backup to {self.backup_path}")
            return
        
        self.backup_path.parent.mkdir(parents=True, exist_ok=True)
        
        with tarfile.open(self.backup_path, 'w:gz') as tar:
            # Add manifest
            manifest = {
                'created_at': subprocess.check_output(['date', '-Is']).decode().strip(),
                'host': subprocess.check_output(['hostname']).decode().strip(),
                'script_version': '2025.08.20-5',
                'components': list(self._data.keys())
            }
            
            manifest_json = json.dumps(manifest, indent=2).encode()
            info = tarfile.TarInfo('manifest.json')
            info.size = len(manifest_json)
            tar.addfile(info, fileobj=tempfile.BytesIO(manifest_json))
            
            # Add data files
            for path, data in self._data.items():
                info = tarfile.TarInfo(f'data/{path}')
                info.size = len(data)
                tar.addfile(info, fileobj=tempfile.BytesIO(data))
    
    def exists(self, path: str) -> bool:
        return path in self._data
    
    def read_file(self, path: str) -> Optional[bytes]:
        return self._data.get(path)
    
    def write_file(self, path: str, data: bytes, mode: Optional[int] = None) -> None:
        self._data[path] = data
    
    def read_directory(self, path: str) -> Optional[bytes]:
        # For backups, directories are stored as tar archives
        return self._data.get(path)
    
    def write_directory(self, path: str, data: bytes) -> None:
        self._data[path] = data

class StateManager:
    """Core state management operations"""
    
    def __init__(self, dry_run: bool = False):
        self.dry_run = dry_run
        self.validate_environment()
    
    def validate_environment(self):
        """Validate that we have necessary tools and permissions"""
        if not self.dry_run:
            if os.geteuid() != 0:
                raise PermissionError("State management operations require root privileges")
        
        # Check for required tools
        required_tools = ['tar', 'date', 'hostname']
        for tool in required_tools:
            if not shutil.which(tool):
                raise RuntimeError(f"Required tool '{tool}' not found in PATH")
    
    def _handle_special_component(self, component: StateComponent, source: StateAdapter, dest: StateAdapter):
        """Handle components with special processing requirements"""
        
        if component.special_handler == 'admin_shadow':
            # Extract only admin user line from shadow file
            shadow_data = source.read_file(component.path)
            if shadow_data:
                lines = shadow_data.decode().splitlines()
                admin_lines = [line for line in lines if line.startswith('admin:')]
                if admin_lines:
                    dest.write_file(f'meta/shadow.admin', admin_lines[0].encode())
                    return True
            return False
        
        elif component.special_handler == 'ssh_config':
            # Handle SSH config, host keys, and sshd_config.d
            base_path = component.path
            
            # Main sshd_config
            config_data = source.read_file(f'{base_path}/sshd_config')
            if config_data:
                dest.write_file(f'{base_path}/sshd_config', config_data)
            
            # sshd_config.d directory
            config_d_data = source.read_directory(f'{base_path}/sshd_config.d')
            if config_d_data:
                dest.write_directory(f'{base_path}/sshd_config.d', config_d_data)
            
            # Host keys
            for key_type in ['rsa', 'ecdsa', 'ed25519']:
                for suffix in ['', '.pub']:
                    key_path = f'{base_path}/ssh_host_{key_type}_key{suffix}'
                    key_data = source.read_file(key_path)
                    if key_data:
                        dest.write_file(key_path, key_data, mode=0o600 if not suffix else 0o644)
            
            return True
        
        elif component.special_handler == 'home_directories':
            # Handle home directories with proper permissions
            home_data = source.read_directory(component.path)
            if home_data:
                dest.write_directory(component.path, home_data)
                return True
            return False
        
        return False
    
    def backup_state(self, source_root: str, backup_path: str) -> bool:
        """Create backup of all state components"""
        logger.info(f"Creating backup from {source_root} to {backup_path}")
        
        source = FilesystemAdapter(source_root, self.dry_run)
        backup = BackupAdapter(backup_path, 'w', self.dry_run)
        
        success = True
        
        for component in SONIC_STATE_COMPONENTS.values():
            logger.info(f"Processing component: {component.name}")
            
            # Try special handler first
            if component.special_handler:
                if self._handle_special_component(component, source, backup):
                    continue
            
            # Standard handling
            if component.component_type == 'file':
                data = source.read_file(component.path)
                if data:
                    backup.write_file(component.path, data)
                elif component.required:
                    logger.warning(f"Required component {component.name} not found")
                    success = False
            
            elif component.component_type == 'directory':
                data = source.read_directory(component.path)
                if data:
                    backup.write_directory(component.path, data)
                elif component.required:
                    logger.warning(f"Required component {component.name} not found")
                    success = False
        
        backup.save_backup()
        logger.info(f"Backup {'completed' if success else 'completed with warnings'}")
        return success
    
    def restore_state(self, backup_path: str, target_root: str) -> bool:
        """Restore state components from backup"""
        logger.info(f"Restoring from {backup_path} to {target_root}")
        
        backup = BackupAdapter(backup_path, 'r', self.dry_run)
        target = FilesystemAdapter(target_root, self.dry_run)
        
        success = True
        
        for component in SONIC_STATE_COMPONENTS.values():
            logger.info(f"Restoring component: {component.name}")
            
            # Handle special components
            if component.special_handler == 'admin_shadow':
                admin_data = backup.read_file('meta/shadow.admin')
                if admin_data and target.exists(component.path):
                    # This would need special shadow file manipulation
                    # For now, just log it
                    logger.info(f"Would restore admin shadow entry")
                continue
            
            # Standard restoration
            if component.component_type == 'file':
                data = backup.read_file(component.path)
                if data:
                    target.write_file(component.path, data)
                elif component.required:
                    logger.warning(f"Required component {component.name} not found in backup")
                    success = False
            
            elif component.component_type == 'directory':
                data = backup.read_directory(component.path)
                if data:
                    target.write_directory(component.path, data)
                elif component.required:
                    logger.warning(f"Required component {component.name} not found in backup")
                    success = False
        
        logger.info(f"Restore {'completed' if success else 'completed with warnings'}")
        return success
    
    def migrate_state(self, source_root: str, target_root: str) -> bool:
        """Direct migration of state between filesystems"""
        logger.info(f"Migrating state from {source_root} to {target_root}")
        
        source = FilesystemAdapter(source_root, self.dry_run)
        target = FilesystemAdapter(target_root, self.dry_run)
        
        success = True
        
        for component in SONIC_STATE_COMPONENTS.values():
            logger.info(f"Migrating component: {component.name}")
            
            # Try special handler first
            if component.special_handler:
                if self._handle_special_component(component, source, target):
                    continue
            
            # Standard migration
            if component.component_type == 'file':
                data = source.read_file(component.path)
                if data:
                    target.write_file(component.path, data)
                elif component.required:
                    logger.warning(f"Required component {component.name} not found")
                    success = False
            
            elif component.component_type == 'directory':
                data = source.read_directory(component.path)
                if data:
                    target.write_directory(component.path, data)
                elif component.required:
                    logger.warning(f"Required component {component.name} not found")
                    success = False
        
        logger.info(f"Migration {'completed' if success else 'completed with warnings'}")
        return success
    
    def validate_state(self, source_root: str) -> bool:
        """Validate that all required state components are present and accessible"""
        logger.info(f"Validating state components in {source_root}")
        
        source = FilesystemAdapter(source_root, self.dry_run)
        success = True
        
        for component in SONIC_STATE_COMPONENTS.values():
            logger.info(f"Validating component: {component.name}")
            
            if component.component_type == 'file':
                if source.exists(component.path):
                    logger.info(f"  ✓ {component.path} exists")
                elif component.required:
                    logger.error(f"  ✗ Required file {component.path} missing")
                    success = False
                else:
                    logger.info(f"  - Optional file {component.path} not present")
            
            elif component.component_type == 'directory':
                if source.exists(component.path):
                    logger.info(f"  ✓ {component.path} directory exists")
                elif component.required:
                    logger.error(f"  ✗ Required directory {component.path} missing")
                    success = False
                else:
                    logger.info(f"  - Optional directory {component.path} not present")
        
        logger.info(f"Validation {'passed' if success else 'failed'}")
        return success

def main():
    """CLI interface for state management"""
    import argparse
    
    parser = argparse.ArgumentParser(description='SONiC State Management')
    parser.add_argument('--dry-run', action='store_true', help='Show what would be done')
    subparsers = parser.add_subparsers(dest='command', help='Commands')
    
    # Backup command
    backup_parser = subparsers.add_parser('backup', help='Create state backup')
    backup_parser.add_argument('--source', default='/', help='Source root path')
    backup_parser.add_argument('--output', required=True, help='Backup file path')
    
    # Restore command  
    restore_parser = subparsers.add_parser('restore', help='Restore state from backup')
    restore_parser.add_argument('--input', required=True, help='Backup file path')
    restore_parser.add_argument('--target', required=True, help='Target root path')
    
    # Migrate command
    migrate_parser = subparsers.add_parser('migrate', help='Migrate state between filesystems')
    migrate_parser.add_argument('--source', default='/', help='Source root path')
    migrate_parser.add_argument('--target', required=True, help='Target root path')
    
    # Validate command
    validate_parser = subparsers.add_parser('validate', help='Validate state components')
    validate_parser.add_argument('--source', default='/', help='Source root path to validate')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return 1
    
    manager = StateManager(dry_run=args.dry_run)
    
    try:
        if args.command == 'backup':
            success = manager.backup_state(args.source, args.output)
        elif args.command == 'restore':
            success = manager.restore_state(args.input, args.target)
        elif args.command == 'migrate':
            success = manager.migrate_state(args.source, args.target)
        elif args.command == 'validate':
            success = manager.validate_state(args.source)
        
        return 0 if success else 1
        
    except Exception as e:
        logger.error(f"Operation failed: {e}")
        return 1

if __name__ == '__main__':
    exit(main())