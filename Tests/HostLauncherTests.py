"""Loader regressions using temporary app fixtures; never launches or signs Roblox."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('host', Path(__file__).resolve().parents[1] / 'Tools/roblox_host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)

class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / 'Original.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.exe = self.app / 'Contents/MacOS/RobloxPlayer'
        self.exe.write_bytes(b'fixture, not executable')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'RobloxPlayer', 'CFBundleIdentifier': 'com.roblox.RobloxPlayer'}))
        self.original = {'com.apple.security.cs.disable-executable-page-protection': True,
                         'com.apple.security.device.camera': True, 'com.apple.security.device.audio-input': True}

    def prepare(self):
        destination = self.root / 'Copy.app'
        seen = {}
        def run(argv):
            if argv[0] == '/usr/bin/ditto':
                shutil.copytree(argv[1], argv[2])
            if '--entitlements' in argv:
                seen.update(plistlib.loads(Path(argv[argv.index('--entitlements')+1]).read_bytes()))
            return ''
        with patch.object(host, 'run', side_effect=run), patch.object(host, 'entitlements', return_value=dict(self.original)), contextlib.redirect_stdout(io.StringIO()):
            host.prepare(SimpleNamespace(source=self.app, destination=destination))
        return destination, seen

    def test_xml_requested_and_preserved(self):
        for stream in ('stdout', 'stderr'):
            result = SimpleNamespace(returncode=0, stdout=b'', stderr=b'')
            setattr(result, stream, b'Executable=test\n' + plistlib.dumps(self.original))
            with patch.object(host.subprocess, 'run', return_value=result) as run:
                self.assertEqual(host.entitlements(self.app), self.original)
                self.assertIn('--xml', run.call_args.args[0])

    def test_unparseable_signing_output_rejected(self):
        result = SimpleNamespace(returncode=0, stdout=b'[Dict]\n[Bool] true', stderr=b'')
        with patch.object(host.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'XML entitlements'):
                host.entitlements(self.app)

    def test_prepare_preserves_entitlements_and_original(self):
        before = host.digest(self.exe)
        copy, values = self.prepare()
        self.assertEqual({k: values[k] for k in self.original}, self.original)
        self.assertEqual(len(values), len(self.original) + 2)
        self.assertTrue(values['com.apple.security.cs.allow-dyld-environment-variables'])
        self.assertTrue(values['com.apple.security.cs.disable-library-validation'])
        self.assertEqual(host.digest(self.exe), before)
        record = json.loads(host.marker_path(copy).read_text())
        self.assertEqual(record['sourceExecutableSHA256'], before)
        self.assertFalse(record['installedAppModified'])

    def test_existing_destination_is_never_overwritten(self):
        with patch.object(host, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'fresh destination'):
                host.prepare(SimpleNamespace(source=self.app, destination=self.app))
            run.assert_not_called()

    def test_nested_destination_rejected(self):
        with patch.object(host, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'outside the source'):
                host.prepare(SimpleNamespace(source=self.app, destination=self.app / 'Nested.app'))
            run.assert_not_called()

    def test_unprepared_app_cannot_launch(self):
        with patch.object(host.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(RuntimeError, 'copy prepared'):
                host.launch(SimpleNamespace(app=self.app))
            popen.assert_not_called()

    def test_changed_copy_cannot_launch(self):
        copy, _ = self.prepare()
        (copy / 'Contents/MacOS/RobloxPlayer').write_bytes(b'changed')
        with patch.object(host.subprocess, 'Popen') as popen:
            with self.assertRaisesRegex(RuntimeError, 'identity changed'):
                host.launch(SimpleNamespace(app=copy))
            popen.assert_not_called()

    def test_child_only_environment_and_private_log(self):
        copy, values = self.prepare()
        (self.root / 'build').mkdir()
        library = self.root / 'build/libMacShadeHost.dylib'
        library.write_bytes(b'fixture')
        effect = self.root / 'Effect.fx'; effect.write_text('fixture')
        args = SimpleNamespace(app=copy, log_directory=self.root / 'logs', fx=effect, preset=None)
        inherited = {'DYLD_INSERT_LIBRARIES': '/unexpected.dylib', 'MACSHADE_AUTOLOAD': '1',
                     'MACSHADE_PRESET': '/unexpected.ini'}
        output = io.StringIO()
        with patch.dict(os.environ, inherited), patch.object(host, 'PACKAGE', self.root), \
             patch.object(host, 'run'), patch.object(host, 'entitlements', return_value=values), \
             patch.object(host.subprocess, 'Popen', return_value=SimpleNamespace(pid=2468)) as popen, \
             contextlib.redirect_stdout(output):
            host.launch(args)
            self.assertEqual(os.environ['DYLD_INSERT_LIBRARIES'], '/unexpected.dylib')
        child = popen.call_args.kwargs['env']
        self.assertEqual(child['DYLD_INSERT_LIBRARIES'], str(library))
        self.assertEqual(child['MACSHADE_EFFECT'], str(effect))
        self.assertNotIn('MACSHADE_AUTOLOAD', child)
        self.assertNotIn('MACSHADE_PRESET', child)
        self.assertEqual(popen.call_args.args[0], [str(copy / 'Contents/MacOS/RobloxPlayer')])
        report = json.loads(output.getvalue())
        self.assertEqual(Path(report['log']).stat().st_mode & 0o777, 0o600)
        self.assertFalse(report['existingRobloxTerminated'])

    def test_run_requires_completed_frames(self):
        report = self.root / 'status.json'
        report.write_text(json.dumps({'pid': 2468, 'hooksInstalled': True, 'processedFrames': 10, 'completedFrames': 0}))
        result = {'pid': 2468, 'loadReport': str(report), 'log': 'test.log'}
        args = SimpleNamespace(source=self.app, fx=None, preset=None)
        with patch.object(Path, 'home', return_value=self.root), patch.object(host, 'prepare'), \
             patch.object(host, 'launch', return_value=result), patch.object(host.os, 'kill'), \
             patch.object(host.time, 'monotonic', side_effect=[0, 0, 16]), patch.object(host.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'not verified'):
                host.start(args)

    def test_run_accepts_verified_completion(self):
        report = self.root / 'status.json'
        report.write_text(json.dumps({'pid': 2468, 'hooksInstalled': True, 'completedFrames': 1}))
        result = {'pid': 2468, 'loadReport': str(report), 'log': 'test.log'}
        args = SimpleNamespace(source=self.app, fx=None, preset=None)
        with patch.object(Path, 'home', return_value=self.root), patch.object(host, 'prepare') as prepare, \
             patch.object(host, 'launch', return_value=result), contextlib.redirect_stdout(io.StringIO()) as output:
            host.start(args)
            self.assertEqual(prepare.call_count, 1)
            self.assertIn('processing Roblox frames', output.getvalue())

    def test_run_reuses_matching_version(self):
        source_hash = host.digest(self.exe)
        cached = self.root / 'Library/Application Support/MacShade/Hosts' / source_hash[:16] / 'Roblox-MacShade.app'
        cached.mkdir(parents=True)
        host.marker_path(cached).write_text(json.dumps({'sourceExecutableSHA256': source_hash}))
        report = self.root / 'status.json'
        report.write_text(json.dumps({'pid': 2468, 'hooksInstalled': True, 'completedFrames': 1}))
        with patch.object(Path, 'home', return_value=self.root), patch.object(host, 'prepare') as prepare, \
             patch.object(host, 'launch', return_value={'pid': 2468, 'loadReport': str(report)}), contextlib.redirect_stdout(io.StringIO()):
            host.start(SimpleNamespace(source=self.app, fx=None, preset=None))
            prepare.assert_not_called()

    def test_run_rejects_unknown_cached_copy(self):
        source_hash = host.digest(self.exe)
        cached = self.root / 'Library/Application Support/MacShade/Hosts' / source_hash[:16] / 'Roblox-MacShade.app'
        cached.mkdir(parents=True)
        with patch.object(Path, 'home', return_value=self.root), patch.object(host, 'launch') as launch:
            with self.assertRaisesRegex(RuntimeError, 'not a verified match'):
                host.start(SimpleNamespace(source=self.app, fx=None, preset=None))
            launch.assert_not_called()

if __name__ == '__main__':
    unittest.main()
