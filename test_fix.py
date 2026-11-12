import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import struct
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name('fix-coh2.sh')
SOURCE = SCRIPT.read_text().split("<<'PYTHON'\n", 1)[1].rsplit('\nPYTHON', 1)[0]


def pe(extra=b''):
    data = bytearray(256)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 128)
    data[128:132] = b'PE\0\0'
    struct.pack_into('<H', data, 132, 0x8664)
    return bytes(data) + extra


class FixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='coh2-script-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bottle = self.root / 'Custom Bottles' / 'CoH2 Test'
        self.system = self.bottle / 'drive_c/windows/system32/ucrtbase.dll'
        self.system.parent.mkdir(parents=True)
        self.original = pe(b'original Wine runtime')
        self.replacement = pe(b'Microsoft runtime fixture')
        self.system.write_bytes(self.original)
        (self.bottle / 'cxbottle.conf').write_text('[Bottle]\n')
        game = self.bottle / 'drive_c/Program Files (x86)/Steam/steamapps/common/Company of Heroes 2/RelicCoH2.exe'
        game.parent.mkdir(parents=True)
        game.write_bytes(pe())
        for name in ['concrt140', 'vcruntime140', 'vcruntime140_1']:
            self.system.with_name(name + '.dll').write_bytes(pe(b'native prerequisite'))
        self.dll = self.root / 'ucrtbase.dll'
        self.dll.write_bytes(self.replacement)
        self.app = self.root / 'CrossOver.app'
        wine = self.app / 'Contents/SharedSupport/CrossOver/bin/wine'
        wine.parent.mkdir(parents=True)
        wine.touch()
        self.preview_app = self.root / 'CrossOver Preview.app'
        preview_wine = self.preview_app / 'Contents/SharedSupport/CrossOver/bin/wine'
        preview_wine.parent.mkdir(parents=True)
        preview_wine.touch()
        self.ns = {'__name__': 'coh2_test_module'}
        exec(compile(SOURCE, str(SCRIPT), 'exec'), self.ns)
        self.ns['DLL_HASH'] = hashlib.sha256(self.replacement).hexdigest()
        self.ns['CROSSOVER_APP'] = self.app
        self.ns['CROSSOVER_PREVIEW_APP'] = self.preview_app
        self.selected_wine = []
        self.closed_checks = []
        self.ns['ensure_closed'] = lambda: self.closed_checks.append(True)
        self.values = dict.fromkeys(self.ns['LIBRARIES'])
        self.values['concrt140'] = 'builtin'
        self.previous = dict(self.values)
        self.fail_once = False
        test = self

        class FakeRegistry:
            def __init__(self, wine, bottle):
                self.wine, self.bottle = wine, bottle
                test.selected_wine.append(wine)

            def read_all(self):
                return dict(test.values)

            def write_all(self, values):
                if test.fail_once:
                    test.fail_once = False
                    test.values['ucrtbase'] = values['ucrtbase']
                    raise RuntimeError('Simulated partial registry failure')
                test.values.update(values)

        self.real_registry = self.ns['Registry']
        self.ns['Registry'] = FakeRegistry
        self.backup = self.bottle / 'coh2-ucrt-fix-backup'

    def run_main(self, *extra):
        argv = ['--bottle-path', str(self.bottle), '--dll', str(self.dll), *extra]
        with contextlib.redirect_stdout(io.StringIO()):
            self.ns['main'](argv)

    def test_apply_and_undo_restore_file_and_overrides(self):
        self.run_main()
        self.assertEqual(self.system.read_bytes(), self.replacement)
        self.assertEqual(self.values, dict.fromkeys(self.ns['LIBRARIES'], 'native,builtin'))
        self.run_main('--undo')
        self.assertEqual(self.system.read_bytes(), self.original)
        self.assertEqual(self.values, self.previous)

    def test_repeat_apply_preserves_first_backup(self):
        self.run_main()
        before = (self.backup / 'manifest.json').read_bytes()
        self.run_main()
        self.assertEqual((self.backup / 'manifest.json').read_bytes(), before)
        self.assertEqual((self.backup / 'ucrtbase.original.dll').read_bytes(), self.original)

    def test_standard_crossover_is_selected_without_flag(self):
        self.run_main()
        self.assertEqual(self.selected_wine[-1], self.app / 'Contents/SharedSupport/CrossOver/bin/wine')

    def test_preview_flag_and_printed_undo_select_preview(self):
        args = ['--bottle-path', str(self.bottle), '--dll', str(self.dll), '--crossoverPreview']
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.ns['main'](args)
        preview_wine = self.preview_app / 'Contents/SharedSupport/CrossOver/bin/wine'
        self.assertEqual(self.selected_wine[-1], preview_wine)
        undo = next(line[len('Undo command: '):] for line in output.getvalue().splitlines() if line.startswith('Undo command: '))
        undo_args = shlex.split(undo)
        self.assertIn('--crossoverPreview', undo_args)
        with contextlib.redirect_stdout(io.StringIO()):
            self.ns['main'](undo_args[2:])
        self.assertEqual(self.selected_wine[-1], preview_wine)
        self.assertEqual(self.system.read_bytes(), self.original)
        self.assertEqual(self.values, self.previous)

    def test_missing_preview_does_not_fall_back_to_standard(self):
        (self.preview_app / 'Contents/SharedSupport/CrossOver/bin/wine').unlink()
        with self.assertRaisesRegex(RuntimeError, 'CrossOver executable not found'):
            self.run_main('--crossoverPreview')
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.system.read_bytes(), self.original)

    def test_partial_registry_failure_rolls_back(self):
        self.fail_once = True
        with self.assertRaisesRegex(RuntimeError, 'previous state was restored'):
            self.run_main()
        self.assertEqual(self.system.read_bytes(), self.original)
        self.assertEqual(self.values, self.previous)

    def interrupt_registry_write_once(self):
        registry = self.ns['Registry']
        original_write = registry.write_all
        interrupted = False
        test = self

        def write(self, values):
            nonlocal interrupted
            if not interrupted:
                interrupted = True
                test.values['ucrtbase'] = values['ucrtbase']
                raise KeyboardInterrupt()
            return original_write(self, values)

        return mock.patch.object(registry, 'write_all', write)

    def test_interrupted_apply_restores_file_and_partial_overrides(self):
        with self.interrupt_registry_write_once():
            with self.assertRaisesRegex(KeyboardInterrupt, 'previous state was restored'):
                self.run_main()
        self.assertEqual(self.system.read_bytes(), self.original)
        self.assertEqual(self.values, self.previous)

    def test_interrupted_undo_restores_applied_state(self):
        self.run_main()
        applied_overrides = dict(self.values)
        with self.interrupt_registry_write_once():
            with self.assertRaisesRegex(KeyboardInterrupt, 'previous state was restored'):
                self.run_main('--undo')
        self.assertEqual(self.system.read_bytes(), self.replacement)
        self.assertEqual(self.values, applied_overrides)

    def test_interrupted_backup_is_removed_before_any_bottle_change(self):
        original_write = self.ns['write_atomic']

        def interrupt_backup(path, data, mode=0o644):
            original_write(path, data, mode)
            if path.name == 'ucrtbase.original.dll':
                raise KeyboardInterrupt()

        self.ns['write_atomic'] = interrupt_backup
        with self.assertRaises(KeyboardInterrupt):
            self.run_main()
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.system.read_bytes(), self.original)
        self.assertEqual(self.values, self.previous)

    def test_apply_and_validation_require_explicit_dll(self):
        for extra in [[], ['--dry-run']]:
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(SystemExit) as result:
                    self.ns['main'](['--bottle-path', str(self.bottle), *extra])
                self.assertEqual(result.exception.code, 2)
                self.assertIn('--dll is required', errors.getvalue())
        self.assertFalse(self.closed_checks)
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.system.read_bytes(), self.original)

    def test_undo_requires_neither_game_nor_extracted_dll(self):
        self.run_main()
        game = self.bottle / 'drive_c/Program Files (x86)/Steam/steamapps/common/Company of Heroes 2/RelicCoH2.exe'
        game.unlink()
        self.dll.unlink()
        with contextlib.redirect_stdout(io.StringIO()):
            self.ns['main'](['--bottle-path', str(self.bottle), '--undo'])
        self.assertEqual(self.system.read_bytes(), self.original)
        self.assertEqual(self.values, self.previous)

    def test_modified_dll_is_not_overwritten_on_undo(self):
        self.run_main()
        self.system.write_bytes(b'separately changed DLL')
        with self.assertRaisesRegex(RuntimeError, 'changed since'):
            self.run_main('--undo')
        self.assertEqual(self.system.read_bytes(), b'separately changed DLL')

    def test_modified_override_is_not_overwritten(self):
        self.run_main()
        self.values['ucrtbase'] = 'native'
        with self.assertRaisesRegex(RuntimeError, 'changed separately'):
            self.run_main('--undo')
        self.assertEqual(self.values['ucrtbase'], 'native')

    def test_backup_tampering_is_rejected(self):
        self.run_main()
        (self.backup / 'ucrtbase.original.dll').write_bytes(b'corrupt backup')
        with self.assertRaisesRegex(RuntimeError, 'checksum'):
            self.run_main('--undo')
        self.assertEqual(self.system.read_bytes(), self.replacement)

    def test_dry_run_never_starts_wine_or_writes_backup(self):
        def fail_if_called(*args):
            raise AssertionError('Dry run accessed Wine')
        self.ns['Registry'] = fail_if_called
        self.run_main('--dry-run')
        self.assertFalse(self.closed_checks)
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.system.read_bytes(), self.original)

    def test_wrong_architecture_is_rejected(self):
        data = bytearray(self.replacement)
        struct.pack_into('<H', data, 132, 0x14c)
        self.dll.write_bytes(data)
        with self.assertRaisesRegex(RuntimeError, 'x64'):
            self.run_main()
        self.assertFalse(self.backup.exists())

    def test_symlink_original_restores_without_modifying_target(self):
        target = self.root / 'shared-runtime.dll'
        target.write_bytes(self.original)
        self.system.unlink()
        self.system.symlink_to(target)
        self.run_main()
        self.assertFalse(self.system.is_symlink())
        self.assertEqual(target.read_bytes(), self.original)
        self.run_main('--undo')
        self.assertTrue(self.system.is_symlink())
        self.assertEqual(os.readlink(self.system), str(target))

    def test_custom_bottle_registry_path_is_explicit(self):
        registry = self.real_registry(self.app / 'Contents/SharedSupport/CrossOver/bin/wine', self.bottle)
        self.assertEqual(registry.env['CX_BOTTLE_PATH'], str(self.bottle.parent))
        self.assertEqual(registry.command[2], self.bottle.name)

    def test_missing_prerequisite_leaves_original_intact(self):
        self.system.with_name('concrt140.dll').unlink()
        with self.assertRaisesRegex(RuntimeError, 'Install Microsoft Visual C'):
            self.run_main()
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.system.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
