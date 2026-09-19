#!/usr/bin/env python3
#
# Copyright (c) 2026 MacShade Authors. All Rights Reserved.
# PROPRIETARY AND CONFIDENTIAL.
# UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
#
"""Prepare and launch an isolated Roblox copy with the MacShade Metal host library.

No remote-thread injector, installed-app patch, global environment modification,
or system-security change is performed. Requires a fresh destination on prepare.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

PACKAGE = Path(__file__).resolve().parents[1]

def run(argv, **kwargs):
    result = subprocess.run([str(a) for a in argv], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f'{argv[0]} failed ({result.returncode})')
    return result.stdout

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def app_info(app):
    app = app.expanduser().resolve(strict=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable_name = info.get('CFBundleExecutable', '')
    if not executable_name or Path(executable_name).name != executable_name:
        raise RuntimeError('Invalid bundle executable name.')
    executable = app / 'Contents/MacOS' / executable_name
    if not executable.is_file():
        raise RuntimeError('The app executable does not exist.')
    return app, executable, info

def entitlements(app):
    p = subprocess.run(['/usr/bin/codesign', '-d', '--xml', '--entitlements', '-', str(app)], capture_output=True)
    # macOS versions differ in which stream carries the XML.
    for data in (p.stdout, p.stderr):
        start = data.find(b'<?xml')
        if start < 0:
            start = data.find(b'<plist')
        end = data.find(b'</plist>', start)
        if start >= 0 and end >= 0:
            return plistlib.loads(data[start:end+8])
    if p.returncode:
        raise RuntimeError('Could not read application entitlements.')
    raise RuntimeError('The app did not return XML entitlements; refusing to replace unknown signing settings.')

def marker_path(app):
    return app.parent / (app.name + '.macshade.json')

def inspect(args):
    app, executable, info = app_info(args.app)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    original = entitlements(app)
    report = {
        'app': str(app), 'executable': str(executable),
        'bundleIdentifier': info.get('CFBundleIdentifier'),
        'sha256': digest(executable),
        'allowsDYLDEnvironment': bool(original.get('com.apple.security.cs.allow-dyld-environment-variables')),
        'disablesLibraryValidation': bool(original.get('com.apple.security.cs.disable-library-validation')),
        'getTaskAllow': bool(original.get('com.apple.security.get-task-allow')),
        'installedAppModified': False,
    }
    print(json.dumps(report, indent=2))

def prepare(args):
    source, executable, info = app_info(args.source)
    if info.get('CFBundleIdentifier') != 'com.roblox.RobloxPlayer':
        raise RuntimeError('Expected the official com.roblox.RobloxPlayer app bundle.')
    destination = args.destination.expanduser().absolute()
    if destination.suffix != '.app':
        raise RuntimeError('The destination must end in .app.')
    if destination.exists() or destination.is_symlink() or marker_path(destination).exists():
        raise RuntimeError('Choose a fresh destination; prepare never overwrites an existing app or marker.')
    if source == destination.resolve() or source in destination.resolve().parents:
        raise RuntimeError('The copy must be outside the source app bundle.')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', source])
    original_hash = digest(executable)
    entitlement_values = entitlements(source)
    entitlement_values['com.apple.security.cs.allow-dyld-environment-variables'] = True
    entitlement_values['com.apple.security.cs.disable-library-validation'] = True
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(['/usr/bin/ditto', source, destination])
    # Only the copied main app is re-signed. Existing nested signatures remain.
    with tempfile.TemporaryDirectory(prefix='macshade-sign-') as directory:
        signing_plist = Path(directory) / 'entitlements.plist'
        signing_plist.write_bytes(plistlib.dumps(entitlement_values))
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime',
             '--entitlements', signing_plist, destination])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', destination])
    if digest(executable) != original_hash:
        raise RuntimeError('The original executable changed during preparation. No launch performed.')
    _, copy_executable, _ = app_info(destination)
    report = {
        'format': 1, 'source': str(source), 'copy': str(destination),
        'sourceExecutableSHA256': original_hash, 'copyExecutableSHA256': digest(copy_executable),
        'createdUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'entitlementsAdded': ['com.apple.security.cs.allow-dyld-environment-variables',
                              'com.apple.security.cs.disable-library-validation'],
        'installedAppModified': False,
        'note': 'Local ad-hoc signature on a separate copy. This does not prove Roblox accepts the copy.',
    }
    marker_path(destination).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

def host_library_path():
    if 'MACSHADE_HOST_LIBRARY' in os.environ:
        p = Path(os.environ['MACSHADE_HOST_LIBRARY']).resolve()
        if p.is_file():
            return p
    bundle_framework = Path(__file__).resolve().parent.parent / 'Frameworks' / 'libMacShadeHost.dylib'
    if bundle_framework.is_file():
        return bundle_framework
    repo_build = PACKAGE / 'build' / 'libMacShadeHost.dylib'
    if repo_build.is_file():
        return repo_build
    raise RuntimeError('Could not find libMacShadeHost.dylib. Please run ./build.sh or reinstall MacShade.')

def host_resources_path():
    if 'MACSHADE_HOST_RESOURCES' in os.environ:
        return Path(os.environ['MACSHADE_HOST_RESOURCES']).resolve()
    bundle_resources = Path(__file__).resolve().parent.parent / 'Resources'
    if (bundle_resources / 'Effects').is_dir():
        return bundle_resources
    return PACKAGE

def launch(args):
    app, executable, _ = app_info(args.app)
    marker = marker_path(app)
    if not marker.is_file():
        raise RuntimeError('Launch requires a copy prepared by this tool; no installed app is launched with injection settings.')
    record = json.loads(marker.read_text())
    if Path(record.get('copy', '')).resolve() != app or digest(executable) != record.get('copyExecutableSHA256'):
        raise RuntimeError('Prepared-copy identity changed. Prepare a fresh copy.')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    current = entitlements(app)
    if not current.get('com.apple.security.cs.allow-dyld-environment-variables') or not current.get('com.apple.security.cs.disable-library-validation'):
        raise RuntimeError('Prepared copy no longer has the expected local loading configuration.')
    library = host_library_path()
    run(['/usr/bin/codesign', '--verify', '--strict', library])
    log_directory = args.log_directory.expanduser().resolve()
    log_directory.mkdir(parents=True, exist_ok=True)
    launch_id = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    log_path = log_directory / ('host-' + launch_id + '.log')
    status_path = log_directory / ('host-' + launch_id + '.json')
    environment = os.environ.copy()
    # A child-only configuration; do not change launchctl or the shell environment.
    environment.pop('DYLD_INSERT_LIBRARIES', None)
    environment.pop('MACSHADE_AUTOLOAD', None)
    environment['DYLD_INSERT_LIBRARIES'] = str(library)
    environment['MACSHADE_HOST_ENABLE'] = '1'
    environment['MACSHADE_HOST_CLEAR_CHILD_ENV'] = '1'
    environment['MACSHADE_HOST_RESOURCES'] = str(host_resources_path())
    environment['MACSHADE_HOST_REPORT'] = str(status_path)
    for key, value in [('MACSHADE_EFFECT', args.fx), ('MACSHADE_PRESET', args.preset)]:
        environment.pop(key, None)
        if value:
            path = value.expanduser().resolve(strict=True)
            if not path.is_file():
                raise RuntimeError(f'Not a file: {path}')
            environment[key] = str(path)
    with log_path.open('xb') as output:
        os.chmod(log_path, 0o600)
        process = subprocess.Popen([str(executable)], cwd=str(executable.parent), env=environment,
                                   stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                   start_new_session=True)
    result = {'pid': process.pid, 'copy': str(app), 'log': str(log_path),
                      'loadReport': str(status_path), 'library': str(library),
                      'status': 'launched; loading and rendered frames must be verified separately',
                      'existingRobloxTerminated': False}
    print(json.dumps(result, indent=2))
    return result

def start(args):
    source, executable, _ = app_info(args.source)
    source_hash = digest(executable)
    directory = Path.home() / 'Library/Application Support/MacShade/Hosts' / source_hash[:16]
    destination = directory / 'Roblox-MacShade.app'
    if not destination.exists():
        prepare(SimpleNamespace(source=source, destination=destination))
    else:
        marker = marker_path(destination)
        if not marker.is_file() or json.loads(marker.read_text()).get('sourceExecutableSHA256') != source_hash:
            raise RuntimeError('The cached copy is not a verified match for this Roblox version. Choose a fresh prepare destination.')
    log_dir = Path.home() / 'Library/Logs/MacShade'
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        log_dir = PACKAGE / 'Logs'
        log_dir.mkdir(parents=True, exist_ok=True)
    result = launch(SimpleNamespace(app=destination, log_directory=log_dir,
                                   fx=args.fx, preset=args.preset))
    deadline = time.monotonic() + 15
    report_path = Path(result['loadReport'])
    while time.monotonic() < deadline:
        if report_path.is_file():
            report = json.loads(report_path.read_text())
            if report.get('pid') == result['pid'] and report.get('hooksInstalled') and report.get('completedFrames', 0) > 0:
                print('MacShade is processing Roblox frames. Press Command-E in its window to choose effects; Command-B toggles them.')
                return
        try:
            os.kill(result['pid'], 0)
        except ProcessLookupError:
            raise RuntimeError(f'The test client exited before rendering was verified. See {result["log"]}')
        time.sleep(0.2)
    raise RuntimeError(f'Launch started, but rendered frames were not verified within 15 seconds. See {result["loadReport"]} and {result["log"]}')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('inspect', help='Read signature and loading configuration only')
    p.add_argument('--app', type=Path, default=Path('/Applications/Roblox.app')); p.set_defaults(function=inspect)
    p = commands.add_parser('prepare', help='Copy and locally sign an isolated app for this loading experiment')
    p.add_argument('--source', type=Path, default=Path('/Applications/Roblox.app'))
    p.add_argument('--destination', type=Path, required=True); p.set_defaults(function=prepare)
    p = commands.add_parser('launch', help='Launch the prepared copy with the Metal host library')
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--log-directory', type=Path, required=True)
    effects = p.add_mutually_exclusive_group()
    effects.add_argument('--fx', type=Path); effects.add_argument('--preset', type=Path)
    p.set_defaults(function=launch)
    p = commands.add_parser('run', help='Prepare or reuse a version-specific copy, launch it and verify frame processing')
    p.add_argument('--source', type=Path, default=Path('/Applications/Roblox.app'))
    effects = p.add_mutually_exclusive_group()
    effects.add_argument('--fx', type=Path); effects.add_argument('--preset', type=Path)
    p.set_defaults(function=start)
    args = parser.parse_args()
    try:
        args.function(args)
    except (RuntimeError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f'MacShade host: {error}', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
