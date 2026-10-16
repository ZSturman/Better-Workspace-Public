#!/usr/bin/env python3
"""Sign every embedded runtime Mach-O with the host's identity, retaining validation."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path)
parser.add_argument('--identity', required=True)
parser.add_argument('--timestamp', action='store_true')
args = parser.parse_args()
if not args.root.is_dir():
    raise SystemExit('Embedded runtime directory is missing')
magic = {bytes.fromhex(value) for value in ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
signed = 0
for path in sorted(args.root.rglob('*')):
    if path.is_symlink() or not path.is_file(): continue
    with path.open('rb') as source:
        if source.read(4) not in magic: continue
    command = ['codesign', '--force', '--sign', args.identity, '--options', 'runtime',
               '--timestamp' if args.timestamp else '--timestamp=none', str(path)]
    subprocess.run(command, check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
    signed += 1
print('Embedded runtime Mach-O files signed and verified:', signed)
