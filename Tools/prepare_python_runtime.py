#!/usr/bin/env python3
"""Prepare an offline, relocatable service runtime from pinned public vendor assets.

Developer/build step only. End users never download dependencies or run pip.
Run with Python 3.12+ on macOS (uses the system archive tool for license metadata).
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from urllib.parse import urlsplit
import zipfile

repo = Path(__file__).resolve().parent.parent
lock_path = repo / 'Support/PythonRuntime.lock.json'
lock_bytes = lock_path.read_bytes()
lock = json.loads(lock_bytes)
lock_digest = hashlib.sha256(lock_bytes).hexdigest()
cache = repo / 'build/PythonRuntimeDownloads'
target = repo / 'Vendor/PythonRuntime'
cache.mkdir(parents=True, exist_ok=True)
target.parent.mkdir(parents=True, exist_ok=True)
if (target / 'manifest.json').is_file():
    manifest = json.loads((target / 'manifest.json').read_text())
    if manifest.get('lock_sha256') == lock_digest and all((target / a / 'python/bin/python3').is_file() for a in lock['architectures']):
        print('Pinned runtime already prepared.'); raise SystemExit(0)
    raise SystemExit('An older generated runtime exists. Move Vendor/PythonRuntime aside before preparing a new pinned version.')
if target.exists():
    raise SystemExit('Refusing to replace an unrecognized Vendor/PythonRuntime directory.')

def asset(url, checksum, name):
    assert urlsplit(url).scheme == 'https'
    assert urlsplit(url).hostname in {'github.com', 'files.pythonhosted.org'}
    path = cache / name
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == checksum:
        return path
    temporary = path.with_suffix(path.suffix + '.download')
    request = urllib.request.Request(url, headers={'User-Agent': 'BetterWorkspaceReleaseBuilder/1.0'})
    with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
        shutil.copyfileobj(response, output)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != checksum:
        temporary.unlink(); raise SystemExit('Vendor asset checksum mismatch: ' + name)
    temporary.replace(path)
    return path

stage = Path(tempfile.mkdtemp(prefix='PythonRuntime.staging-', dir=target.parent))
try:
    wheel = asset(lock['watchdog']['wheel_url'], lock['watchdog']['sha256'], 'watchdog-universal2.whl')
    for architecture, spec in lock['architectures'].items():
        print('Preparing', architecture, flush=True)
        archive = asset(spec['runtime_url'], spec['runtime_sha256'], 'cpython-' + architecture + '.tar.gz')
        arch_root = stage / architecture; arch_root.mkdir()
        with tarfile.open(archive, 'r:gz') as bundle:
            bundle.extractall(arch_root, filter='data')
        packages = arch_root / 'python/lib/python3.13/site-packages'
        with zipfile.ZipFile(wheel) as bundle:
            for entry in bundle.infolist():
                name = Path(entry.filename)
                if name.is_absolute() or '..' in name.parts: raise SystemExit('Unsafe wheel path')
            bundle.extractall(packages)
        # Install-only Python omits dependency license texts. Retain those from the
        # matching verified full distribution, without embedding its build objects.
        full = asset(spec['notices_url'], spec['notices_sha256'], 'cpython-' + architecture + '-full.tar.zst')
        notices_stage = stage / ('notices-source-' + architecture); notices_stage.mkdir()
        subprocess.run(['tar', '-xf', str(full), '-C', str(notices_stage), 'python/licenses', 'python/PYTHON.json'], check=True)
        notices = stage / 'Notices' / architecture
        notices.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(notices_stage / 'python/licenses', notices)
        shutil.copy2(notices_stage / 'python/PYTHON.json', notices / 'distribution-metadata.json')
        shutil.rmtree(notices_stage)
    (stage / 'manifest.json').write_text(json.dumps({'python_version': lock['python_version'],
        'watchdog_version': lock['watchdog']['version'], 'release': lock['release'],
        'lock_sha256': lock_digest, 'architectures': list(lock['architectures'])}, indent=2) + '\n')
    (stage / 'Notices/README.txt').write_text('Better Workspace embeds CPython from Astral python-build-standalone and watchdog from PyPI.\n'
        'License texts and distribution metadata for each architecture are retained in this directory; watchdog and pip notices remain in their dist-info directories.\n'
        'Sources: https://github.com/astral-sh/python-build-standalone and https://pypi.org/project/watchdog/6.0.0/\n')
    stage.rename(target)
    print('Prepared pinned runtimes and notices:', target)
finally:
    if stage.exists(): shutil.rmtree(stage)
