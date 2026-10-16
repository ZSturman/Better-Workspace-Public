#!/usr/bin/env python3
"""Export a clean, history-free release snapshot; never copy private QA evidence."""
import argparse
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = {
    'archive_release.sh', 'check_release_archive.py', 'prepare_python_runtime.py',
    'sign_bundled_python.py', 'verify_mac_download.sh', 'verify_packaged_service.py',
    'store_sample_fixture.swift', 'export_public_source.py',
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists():
        raise SystemExit('Destination must not exist; refusing to overwrite anything.')
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    selected = [p for p in paths if p and (
        p.startswith(('Sources/', 'Tests/', 'Support/', 'Resources/', 'BackgroundService/'))
        or p in {'.gitignore', 'project.yml', 'LICENSE'}
        or p.startswith('Tools/') and Path(p).name in TOOLS)]
    # Match concrete credentials, not placeholder words or key-management code.
    secret = re.compile(rb'-----BEGIN (?:EC |RSA |OPENSSH )?PRIVATE KEY-----|(?:gh[pousr]_|ntn_|secret_)[A-Za-z0-9]{25,}')
    for relative in selected:
        data = (ROOT / relative).read_bytes()
        if secret.search(data):
            raise SystemExit(f'Credential-shaped content in {relative}; export aborted.')
    destination.mkdir(parents=True)
    for relative in selected:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    for name in ['README.md', 'AGENTS.md']:
        shutil.copy2(ROOT / 'docs/public-source' / name, destination / name)
    for name in ['GETTING_STARTED.md', 'RELEASE_NOTES_1.0.md']:
        target = destination / 'docs' / name
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'docs' / name, target)
    image_dir = destination / 'docs/images'
    image_dir.mkdir(parents=True)
    for platform in ['mac', 'iphone', 'ipad']:
        shutil.copy2(ROOT / f'docs/images/cohesive-2026-10-15/{platform}-personal-overview.png', image_dir / f'{platform}-sample.png')
    print(f'Exported {len(selected)} allowlisted source files, public docs and three sample screenshots to {destination}.')

if __name__ == '__main__':
    main()
