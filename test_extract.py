import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('extract-ucrtbase.sh')
SOURCE = SCRIPT.read_text().split("<<'PYTHON'\n", 1)[1].rsplit('\nPYTHON', 1)[0]


def pe(extra=b'', machine=0x8664):
    data = bytearray(256)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 128)
    data[128:132] = b'PE\0\0'
    struct.pack_into('<H', data, 132, machine)
    return bytes(data) + extra


def cab(members):
    table = bytearray()
    payload = bytearray()
    for name, data in members:
        table.extend(struct.pack('<IIHHHH', len(data), len(payload), 0, 0, 0, 0))
        table.extend(name.encode('cp1252') + b'\0')
        payload.extend(data)
    assert len(payload) < 32768
    data_offset = 44 + len(table)
    header = struct.pack('<4sIIIIIBBHHHHH', b'MSCF', 0, data_offset + 8 + len(payload),
                         0, 44, 0, 3, 1, 1, len(members), 0, 0, 0)
    folder = struct.pack('<IHH', data_offset, 1, 0)
    block = struct.pack('<IHH', 0, len(payload), len(payload)) + payload
    return header + folder + table + block


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ucrt-extractor-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'Installer folder with spaces'
        self.folder.mkdir()
        self.installer = self.folder / 'vc_redist.x64.exe'
        self.dll = pe(b'UCRT test fixture')
        self.ns = {'__name__': 'extractor_test_module'}
        exec(compile(SOURCE, str(SCRIPT), 'exec'), self.ns)

    def nested_installer(self, dll=None):
        nested = cab([('ucrtbase.dll', self.dll if dll is None else dll), ('other.dll', b'not needed')])
        bootstrap = cab([('u0', b'bootstrap UI')])
        return pe(bootstrap + cab([('a0', b'MSI fixture'), ('a10', nested)]), machine=0x14c)

    def run_main(self, *extra):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.ns['main']([str(self.installer), *extra])
        return output.getvalue()

    def test_extracts_nested_a10_beside_installer(self):
        self.installer.write_bytes(self.nested_installer())
        output = self.run_main()
        self.assertEqual((self.folder / 'ucrtbase.dll').read_bytes(), self.dll)
        self.assertIn(str(self.folder / 'ucrtbase.dll'), output)
        self.assertFalse((self.folder / 'other.dll').exists())

    def test_direct_payload_is_supported(self):
        self.installer.write_bytes(pe(cab([('ucrtbase.dll_amd64', self.dll)])))
        self.run_main()
        self.assertEqual((self.folder / 'ucrtbase.dll').read_bytes(), self.dll)

    def test_false_cab_signature_is_ignored(self):
        self.installer.write_bytes(pe(b'MSCF' + b'\0' * 60 + self.nested_installer()[256:]))
        self.run_main()
        self.assertEqual((self.folder / 'ucrtbase.dll').read_bytes(), self.dll)

    def test_installer_without_ucrt_has_actionable_error(self):
        self.installer.write_bytes(pe(cab([('a4', cab([('vcruntime140.dll', pe())]))])))
        with self.assertRaisesRegex(RuntimeError, 'does not contain ucrtbase.dll'):
            self.run_main()
        self.assertFalse((self.folder / 'ucrtbase.dll').exists())

    def test_x86_dll_is_rejected(self):
        self.installer.write_bytes(self.nested_installer(pe(machine=0x14c)))
        with self.assertRaisesRegex(RuntimeError, 'not the Windows x64'):
            self.run_main()
        self.assertFalse((self.folder / 'ucrtbase.dll').exists())

    def test_existing_different_dll_is_preserved(self):
        self.installer.write_bytes(self.nested_installer())
        target = self.folder / 'ucrtbase.dll'
        target.write_bytes(b'existing DLL')
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            self.run_main()
        self.assertEqual(target.read_bytes(), b'existing DLL')

    def test_force_explicitly_replaces_existing_file(self):
        self.installer.write_bytes(self.nested_installer())
        target = self.folder / 'ucrtbase.dll'
        target.write_bytes(b'existing DLL')
        self.run_main('--force')
        self.assertEqual(target.read_bytes(), self.dll)

    def test_repeat_run_does_not_rewrite_identical_file(self):
        self.installer.write_bytes(self.nested_installer())
        self.run_main()
        target = self.folder / 'ucrtbase.dll'
        before = target.stat().st_mtime_ns
        self.assertIn('Already extracted', self.run_main())
        self.assertEqual(target.stat().st_mtime_ns, before)

    def test_multiple_distinct_x64_dlls_are_rejected(self):
        self.installer.write_bytes(pe(cab([('a10', cab([('ucrtbase.dll', self.dll)])),
                                          ('a11', cab([('ucrtbase.dll', pe(b'different version'))]))])))
        with self.assertRaisesRegex(RuntimeError, 'multiple different'):
            self.run_main()
        self.assertFalse((self.folder / 'ucrtbase.dll').exists())

    def test_non_executable_input_is_rejected(self):
        self.installer.write_bytes(b'not an executable')
        with self.assertRaisesRegex(RuntimeError, 'not a Windows installer'):
            self.run_main()

    def test_wine_dll_is_rejected(self):
        data = bytearray(self.dll)
        data[64:80] = b'Wine builtin DLL'
        self.installer.write_bytes(self.nested_installer(bytes(data)))
        with self.assertRaisesRegex(RuntimeError, 'Wine replacement'):
            self.run_main()

    def test_archive_paths_do_not_escape_to_disk(self):
        self.installer.write_bytes(pe(cab([('ucrtbase.dll', self.dll), ('../escaped.txt', b'escape')])))
        self.run_main()
        self.assertFalse((self.root / 'escaped.txt').exists())
        self.assertEqual((self.folder / 'ucrtbase.dll').read_bytes(), self.dll)


if __name__ == '__main__':
    unittest.main()
