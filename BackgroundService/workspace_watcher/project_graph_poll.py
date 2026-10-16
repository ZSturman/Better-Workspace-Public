"""Schedule the app's own read-only Notion checker; never receive credentials or apply edits."""
from __future__ import annotations
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

class ProjectGraphPoller:
    def __init__(self, executable: str | None = None, interval: float = 900):
        self.executable = executable or os.environ.get("BETTER_WORKSPACE_EXECUTABLE")
        self.interval = interval
        self.next_check = 0.0
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="project-graph")
        self.future = None

    def tick(self, now: float | None = None):
        now = time.monotonic() if now is None else now
        if not self.executable or now < self.next_check or self.future is not None and not self.future.done():
            return
        self.next_check = now + self.interval
        self.future = self.executor.submit(self._check)

    def _check(self):
        try:
            result = subprocess.run([self.executable, "--notion", "check"], capture_output=True, timeout=850, check=False)
            return result.returncode
        except (OSError, subprocess.TimeoutExpired):
            return -1

    def stop(self):
        self.executor.shutdown(wait=False, cancel_futures=True)
