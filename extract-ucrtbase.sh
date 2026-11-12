#!/bin/bash
# Extracts a Windows x64 UCRT beside a local installer. Never installs or downloads anything.
set -eu
exec python3 - "$@" <<'PYTHON'
import argparse
import hashlib
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

COH2_DLL_SHA256 = '05fdef5f91cd38055021c6e7ae83b32936b30b6032f7ccf05b2b50233ab7fe9b'
MAX_MEMBER_SIZE = 64 * 1024 * 1024
MAX_EXPANDED_SIZE = 256 * 1024 * 1024
MAX_CABINETS = 128
TAR = '/usr/bin/bsdtar'


def cabinets(data):
    """Find bounded CAB containers embedded in a Burn installer or CAB payload."""
    position = 0
    while True:
        position = data.find(b'MSCF', position)
        if position < 0:
            return
        start = position
        position += 4
        if start + 36 > len(data):
            continue
        header = struct.unpack_from('<4sIIIIIBBHHHHH', data, start)
        _, reserved1, size, reserved2, files_offset, reserved3, minor, major, folders, count, flags, _, _ = header
        if (reserved1 or reserved2 or reserved3 or major != 1 or minor != 3
                or not folders or not count or flags & ~7
                or size < 36 or start + size > len(data)
                or files_offset < 36 or files_offset >= size):
            continue
        cab = data[start:start + size]
        cursor = files_offset
        members = []
        try:
            for _ in range(count):
                if cursor + 16 > size:
                    raise ValueError('Truncated CAB file table')
                file_size, _, _, _, _, attributes = struct.unpack_from('<IIHHHH', cab, cursor)
                cursor += 16
                end = cab.find(b'\0', cursor)
                if end < 0:
                    raise ValueError('Unterminated CAB filename')
                encoding = 'utf-8' if attributes & 0x80 else 'cp1252'
                name = cab[cursor:end].decode(encoding)
                if not name:
                    raise ValueError('Empty CAB filename')
                members.append((name, file_size))
                cursor = end + 1
        except (ValueError, UnicodeError, struct.error):
            continue
        yield cab, members
        position = start + size


def validate_dll(data):
    if len(data) < 64 or data[:2] != b'MZ':
        return 'not a Windows DLL'
    pe = struct.unpack_from('<I', data, 60)[0]
    if pe + 6 > len(data) or data[pe:pe + 4] != b'PE\0\0':
        return 'invalid Windows PE header'
    if struct.unpack_from('<H', data, pe + 4)[0] != 0x8664:
        return 'not the Windows x64 version'
    if b'Wine builtin DLL' in data[:256]:
        return 'a Wine replacement rather than a Microsoft DLL'
    return None


def extract_dll(data):
    queue = [(data, 0)]
    seen_cabs = set()
    found = {}
    rejections = []
    failures = []
    expanded = 0
    with tempfile.TemporaryDirectory(prefix='extract-ucrtbase-') as temporary:
        folder = Path(temporary)
        while queue:
            payload, depth = queue.pop(0)
            for cab, members in cabinets(payload):
                identity = hashlib.sha256(cab).hexdigest()
                if identity in seen_cabs:
                    continue
                if len(seen_cabs) >= MAX_CABINETS:
                    raise RuntimeError('Installer has too many CAB containers to inspect.')
                seen_cabs.add(identity)
                cab_path = folder / (str(len(seen_cabs)) + '.cab')
                cab_path.write_bytes(cab)
                for name, size in members:
                    is_ucrt = bool(re.search(r'(?:^|[\\/])ucrtbase\.dll(?:_[a-z0-9]+)?$', name, re.I))
                    # Burn installers label payloads a0, a1, ...; also support nested .cab files.
                    is_container = bool(re.search(r'(?:^|[\\/])a[0-9]+$|\.cab$', name, re.I))
                    if not is_ucrt and not is_container:
                        continue
                    if size > MAX_MEMBER_SIZE or expanded + size > MAX_EXPANDED_SIZE:
                        raise RuntimeError('Installer exceeds the extraction size limit.')
                    if is_container and depth >= 4:
                        raise RuntimeError('Installer exceeds the nested CAB depth limit.')
                    expanded += size
                    # -O writes the member to stdout; archive paths are never extracted to disk.
                    result = subprocess.run([TAR, '-xOf', str(cab_path), '--', name],
                                            capture_output=True, timeout=90)
                    if result.returncode:
                        failures.append(result.stderr.decode(errors='replace').strip()[:300])
                        continue
                    member = result.stdout
                    if len(member) != size:
                        failures.append('Extracted member size did not match its CAB metadata.')
                        continue
                    if is_ucrt:
                        reason = validate_dll(member)
                        if reason:
                            rejections.append(reason)
                        else:
                            found[hashlib.sha256(member).hexdigest()] = member
                    elif b'MSCF' in member:
                        queue.append((member, depth + 1))
    if len(found) > 1:
        raise RuntimeError('Installer contains multiple different x64 UCRT DLLs; refusing to choose one automatically.')
    if found:
        return next(iter(found.values()))
    if rejections:
        raise RuntimeError('No suitable ucrtbase.dll found: ' + '; '.join(sorted(set(rejections))) + '.')
    if failures:
        raise RuntimeError('Could not read the installer CAB payloads: ' + failures[0])
    raise RuntimeError('This installer does not contain ucrtbase.dll. The CoH2 workaround uses the older Visual C++ 2015 x64 installer; recent v14 installers may omit it.')


def main(argv=None):
    parser = argparse.ArgumentParser(prog='extract-ucrtbase.sh',
        description='Extract Windows x64 ucrtbase.dll into the same folder as a local Microsoft installer .exe. Requires Python 3 and macOS bsdtar. No downloads.')
    parser.add_argument('installer', type=Path, help='Path to the existing Microsoft installer .exe')
    parser.add_argument('--force', action='store_true', help='Replace an existing, different ucrtbase.dll in that folder')
    args = parser.parse_args(argv)
    installer = args.installer.expanduser().absolute()
    data = installer.read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        raise RuntimeError('Input is not a Windows installer executable.')
    pe = struct.unpack_from('<I', data, 60)[0]
    if pe + 4 > len(data) or data[pe:pe + 4] != b'PE\0\0':
        raise RuntimeError('Input has an invalid Windows PE header.')
    if not Path(TAR).is_file():
        raise RuntimeError('macOS bsdtar was not found at ' + TAR)
    dll = extract_dll(data)
    digest = hashlib.sha256(dll).hexdigest()
    destination = installer.parent / 'ucrtbase.dll'
    if os.path.lexists(destination):
        if destination.is_file() and destination.read_bytes() == dll:
            print('Already extracted:', destination)
            print('SHA-256:', digest)
            return
        if not args.force:
            raise RuntimeError('A different ucrtbase.dll already exists in the installer folder. Use --force to replace it.')
        if destination.is_dir():
            raise RuntimeError('Destination is a directory: ' + str(destination))
    fd, temporary = tempfile.mkstemp(prefix='.ucrtbase-', dir=str(installer.parent))
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(dll)
        os.chmod(temporary, 0o644)
        if args.force:
            os.replace(temporary, destination)
        else:
            # Refuse to overwrite a file created by another process during extraction.
            os.link(temporary, destination)
            os.unlink(temporary)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)
    print('Extracted:', destination)
    print('Architecture: Windows x64')
    print('SHA-256:', digest)
    print('Matches the tested CoH2 workaround DLL:', 'yes' if digest == COH2_DLL_SHA256 else 'no')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('Error:', error, file=sys.stderr)
        sys.exit(1)
PYTHON
