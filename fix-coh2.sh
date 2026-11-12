#!/bin/bash
# Requires Python 3. Uses an already-extracted Microsoft DLL; never downloads files.
set -eu
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
export COH2_FIX_SCRIPT_DIR="$script_dir"
exec python3 - "$@" <<'PYTHON'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys
import tempfile

DLL_HASH = '05fdef5f91cd38055021c6e7ae83b32936b30b6032f7ccf05b2b50233ab7fe9b'
KEY = r'HKCU\Software\Wine\AppDefaults\RelicCoH2.exe\DllOverrides'
LIBRARIES = ('ucrtbase', 'concrt140', 'vcruntime140', 'vcruntime140_1')
LOAD_ORDER = 'native,builtin'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check_pe(data, description):
    if len(data) < 64 or data[:2] != b'MZ':
        raise RuntimeError(f'{description} is not a Windows DLL.')
    pe = struct.unpack_from('<I', data, 60)[0]
    if pe + 6 > len(data) or data[pe:pe + 4] != b'PE\0\0':
        raise RuntimeError(f'{description} has an invalid PE header.')
    if struct.unpack_from('<H', data, pe + 4)[0] != 0x8664:
        raise RuntimeError(f'{description} must be the Windows x64 version.')
    if b'Wine builtin DLL' in data[:256]:
        raise RuntimeError(f'{description} is Wine\'s replacement, not Microsoft\'s DLL.')


def write_atomic(path, data, mode=0o644):
    fd, temporary = tempfile.mkstemp(prefix='.coh2-fix-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def file_state(path):
    return {
        'bytes': path.read_bytes(),
        'mode': path.stat().st_mode & 0o777,
        'symlink': os.readlink(path) if path.is_symlink() else None,
    }


def restore_file(path, state):
    if state['symlink'] is None:
        write_atomic(path, state['bytes'], state['mode'])
    else:
        fd, temporary = tempfile.mkstemp(prefix='.coh2-link-', dir=str(path.parent))
        os.close(fd)
        os.unlink(temporary)
        try:
            os.symlink(state['symlink'], temporary)
            os.replace(temporary, path)
        finally:
            if os.path.lexists(temporary):
                os.unlink(temporary)


class Registry:
    def __init__(self, wine, bottle_path):
        self.command = [str(wine), '--bottle', bottle_path.name, '--no-update', '--cx-app', 'reg.exe']
        self.env = dict(os.environ, WINEDEBUG='-all', CX_BOTTLE_PATH=str(bottle_path.parent))

    def run(self, *args):
        result = subprocess.run(self.command + list(args), env=self.env,
                                capture_output=True, text=True, timeout=90)
        return result.returncode, result.stdout + result.stderr

    def read_all(self):
        code, output = self.run('query', r'HKCU\Software\Wine')
        if code:
            raise RuntimeError('Cannot access the bottle registry: ' + output.strip())
        values = {}
        for name in LIBRARIES:
            code, output = self.run('query', KEY, '/v', name)
            if code == 1 and re.search(r'(unable to find|cannot find|not found|does not exist)', output, re.I):
                values[name] = None
                continue
            match = re.search(r'^\s*' + re.escape(name) + r'\s+REG_SZ\s+(.*?)\s*$', output, re.M | re.I)
            if code or not match:
                raise RuntimeError(f'Cannot read {name} override: {output.strip()}')
            values[name] = match.group(1)
        return values

    def write_all(self, values):
        current = self.read_all()
        for name, value in values.items():
            if current[name] == value:
                continue
            args = ('delete', KEY, '/v', name, '/f') if value is None else (
                'add', KEY, '/v', name, '/t', 'REG_SZ', '/d', value, '/f')
            code, output = self.run(*args)
            if code:
                raise RuntimeError(f'Cannot update {name}: {output.strip()}')
        if self.read_all() != values:
            raise RuntimeError('DLL override verification failed.')


def ensure_closed():
    result = subprocess.run(['ps', '-ax', '-o', 'args='], capture_output=True, text=True, check=True)
    if any(re.search(r'''(?:^|[ /\\])(?:RelicCoH2|Steam)\.exe(?:$|\s|["'])''', line, re.I)
           for line in result.stdout.splitlines()):
        raise RuntimeError('Close CoH2 and Windows Steam before running this script.')


def save_backup(folder, state, overrides):
    folder.mkdir(mode=0o700)
    try:
        write_atomic(folder / 'ucrtbase.original.dll', state['bytes'], 0o600)
        manifest = {'schema': 1, 'original_sha256': sha(state['bytes']),
                    'original_mode': state['mode'], 'original_symlink': state['symlink'],
                    'previous_overrides': overrides, 'replacement_sha256': DLL_HASH}
        write_atomic(folder / 'manifest.json', (json.dumps(manifest, indent=2) + '\n').encode(), 0o600)
    except Exception:
        # Remove only the new, incomplete backup created by this call.
        for name in ('ucrtbase.original.dll', 'manifest.json'):
            candidate = folder / name
            if candidate.exists():
                candidate.unlink()
        folder.rmdir()
        raise


def load_backup(folder):
    manifest = json.loads((folder / 'manifest.json').read_text())
    if (manifest.get('schema') != 1 or manifest.get('replacement_sha256') != DLL_HASH
            or set(manifest.get('previous_overrides', {})) != set(LIBRARIES)):
        raise RuntimeError('Backup manifest has an unsupported format.')
    data = (folder / 'ucrtbase.original.dll').read_bytes()
    if sha(data) != manifest['original_sha256']:
        raise RuntimeError('Original DLL backup failed checksum verification.')
    return manifest, data


def change(system, registry, desired_file, desired_overrides):
    before = file_state(system)
    overrides_before = registry.read_all()
    try:
        restore_file(system, desired_file)
        registry.write_all(desired_overrides)
        if sha(system.read_bytes()) != sha(desired_file['bytes']):
            raise RuntimeError('Installed DLL failed checksum verification.')
    except Exception as error:
        # Restore the state from this invocation, including partial registry writes.
        try:
            restore_file(system, before)
            registry.write_all(overrides_before)
        except Exception as rollback_error:
            raise RuntimeError(f'{error}; automatic rollback also failed: {rollback_error}') from error
        raise RuntimeError(f'{error}; the previous state was restored.') from error


def main(argv=None):
    parser = argparse.ArgumentParser(prog='fix-coh2.sh', description='Apply or undo the CoH2 UCRT workaround in CrossOver. No downloads.')
    location = parser.add_mutually_exclusive_group()
    location.add_argument('--bottle', help='Bottle name in the default CrossOver Bottles folder')
    location.add_argument('--bottle-path', type=Path, help='Full path to a bottle in a custom location')
    parser.add_argument('--dll', type=Path, help='Extracted Microsoft ucrtbase.dll; defaults to beside this script')
    parser.add_argument('--crossover', type=Path, default=Path('/Applications/CrossOver.app'), help='CrossOver application path')
    parser.add_argument('--undo', action='store_true', help='Restore the automatically saved original DLL and overrides')
    parser.add_argument('--dry-run', action='store_true', help='Validate files and show the plan without starting Wine or changing the bottle')
    args = parser.parse_args(argv)
    name = args.bottle or 'Company of Heroes 2'
    if not args.bottle_path and (name in ('.', '..') or '/' in name or '\\' in name):
        parser.error('Use a bottle name, or --bottle-path for a full path.')
    bottle = args.bottle_path.expanduser() if args.bottle_path else (
        Path.home() / 'Library/Application Support/CrossOver/Bottles' / name)
    bottle = bottle.absolute()
    if not (bottle / 'cxbottle.conf').is_file():
        raise RuntimeError(f'CrossOver bottle not found: {bottle}')
    system = bottle / 'drive_c/windows/system32/ucrtbase.dll'
    game = bottle / 'drive_c/Program Files (x86)/Steam/steamapps/common/Company of Heroes 2/RelicCoH2.exe'
    if not system.is_file() or not game.is_file():
        raise RuntimeError('CoH2 or the system UCRT was not found in this bottle. Custom Steam library locations are not supported.')
    wine = args.crossover.expanduser() / 'Contents/SharedSupport/CrossOver/bin/wine'
    if not wine.is_file():
        raise RuntimeError(f'CrossOver executable not found: {wine}')
    backup = bottle / 'coh2-ucrt-fix-backup'
    native_overrides = dict.fromkeys(LIBRARIES, LOAD_ORDER)
    if args.undo:
        manifest, original = load_backup(backup)
        if sha(system.read_bytes()) not in (DLL_HASH, manifest['original_sha256']):
            raise RuntimeError('The system DLL has changed since this fix. Refusing to overwrite it.')
        desired_file = {'bytes': original, 'mode': manifest['original_mode'], 'symlink': manifest['original_symlink']}
        desired_overrides = manifest['previous_overrides']
    else:
        source = args.dll.expanduser() if args.dll else Path(os.environ['COH2_FIX_SCRIPT_DIR']) / 'ucrtbase.dll'
        data = source.read_bytes()
        check_pe(data, 'Replacement UCRT')
        if sha(data) != DLL_HASH:
            raise RuntimeError('The replacement UCRT does not match the tested x64 DLL (version 10.0.10137.0).')
        for name in LIBRARIES[1:]:
            path = system.parent / (name + '.dll')
            if not path.is_file():
                raise RuntimeError('Install Microsoft Visual C++ x64 in this bottle first: missing ' + path.name)
            check_pe(path.read_bytes(), path.name)
        desired_file = {'bytes': data, 'mode': 0o644, 'symlink': None}
        desired_overrides = native_overrides
        if backup.exists():
            manifest, _ = load_backup(backup)
            if sha(system.read_bytes()) not in (DLL_HASH, manifest['original_sha256']):
                raise RuntimeError('The system DLL changed after the original backup. Refusing to overwrite it.')
    print('Bottle:', bottle)
    print('Action:', 'restore previous setup' if args.undo else 'install Microsoft UCRT and set CoH2-specific native DLL overrides')
    print('Automatic backup:', backup)
    if args.dry_run:
        print('Dry run complete. No bottle files or registry values were changed.')
        return
    ensure_closed()
    registry = Registry(wine, bottle)
    current_overrides = registry.read_all()
    if backup.exists():
        manifest, _ = load_backup(backup)
        for name in LIBRARIES:
            if current_overrides[name] not in (native_overrides[name], manifest['previous_overrides'][name]):
                raise RuntimeError(f'{name} override was changed separately; refusing to overwrite it.')
    else:
        save_backup(backup, file_state(system), current_overrides)
    change(system, registry, desired_file, desired_overrides)
    print('Previous DLL and overrides restored.' if args.undo else 'Workaround installed. Existing original backup preserved.')
    print('Graphics, MSync, Windows version, and Steam Cloud settings were not changed.')
    if not args.undo:
        print('Next: launch CoH2, verify native runtime loading, and test a private multiplayer match.')
    print('Undo command: bash fix-coh2.sh --bottle-path ' + shlex.quote(str(bottle)) + ' --undo')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('Error:', error, file=sys.stderr)
        sys.exit(1)
PYTHON
