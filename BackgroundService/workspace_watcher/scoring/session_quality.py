"""Conservative evidence checks for historical filesystem-derived sessions.

Do not estimate a noise-time fraction from a capped list of distinct filenames.
Raw sessions stay intact; only clearly unsupported records are excluded here.
"""
import json
from pathlib import PurePosixPath

NOISE_DIRECTORIES = {
    '.git', '.sites-runtime', '.wrangler', '.next', 'node_modules', '__pycache__',
    '.pytest_cache', '.mypy_cache', '.ruff_cache', '.venv', 'venv', 'DerivedData',
}
NOISE_FILENAMES = {'.DS_Store', 'Project.betterproject', 'project-scoring.db',
                   'project-scoring.db-wal', 'project-scoring.db-shm'}


def assess_session(row):
    if 'files_json' in row:
        files = json.loads(row['files_json'])
    elif 'files' in row:
        files = row['files']
    else:
        return {'eligible': True, 'reason': 'file_evidence_unavailable', 'mixed': False, 'capped': False}
    if not isinstance(files, list) or any(not isinstance(f, str) or not f for f in files):
        raise ValueError('invalid session file evidence')
    def noise(path):
        p = PurePosixPath(path)
        return bool(set(p.parts) & NOISE_DIRECTORIES) or p.name in NOISE_FILENAMES or p.suffix in {'.pyc', '.pyo'}
    noisy = sum(noise(f) for f in files)
    capped = len(files) >= 100  # upstream Sessionizer retains only the first 100 unique paths
    if not files:
        return {'eligible': False, 'reason': 'directory_only', 'mixed': False, 'capped': False}
    if noisy == len(files) and not capped:
        return {'eligible': False, 'reason': 'background_files_only', 'mixed': False, 'capped': False}
    return {'eligible': True, 'reason': 'capped_background_sample' if noisy == len(files) else 'file_evidence',
            'mixed': noisy > 0, 'capped': capped}
