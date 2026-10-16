#!/usr/bin/env python3
"""Drives DeviceSyncUITests on a physical iPhone and iPad against the running Mac app.

Each step is one UI test. Between steps this script checks what actually reached the
Mac's Workspace, and makes the Mac-side changes (an edit, a rename) a person would make.
Everything it creates or touches is named `BW QA <id>`; both test items end in the Trash.

    Tests/DeviceSyncQA/run.py --derived-data <DerivedData> --iphone <UDID> --ipad <UDID>

Build first:  xcodebuild ... -scheme BetterWorkspaceMobile -destination 'generic/platform=iOS'
              -derivedDataPath <DerivedData> -allowProvisioningUpdates build-for-testing
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

WORKSPACE = Path.home() / "Workspace"
TRASH = Path.home() / ".Trash"
QUEUE = WORKSPACE / "To Do"
TEST_CLASS = "BetterWorkspaceMobileUITests/DeviceSyncUITests"
results: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail else ""), flush=True)


class Step(threading.Thread):
    """One UI test on one device, run in the background so its signals can be followed."""

    def __init__(self, args, device: str, test: str, qa_id: str, log: Path):
        super().__init__(daemon=True)
        self.command = ["xcodebuild", "test-without-building", "-project", "BetterWorkspace.xcodeproj",
                        "-scheme", "BetterWorkspaceMobile", "-destination", f"id={device}",
                        "-derivedDataPath", args.derived_data, "-resultBundlePath", str(log.with_suffix(".xcresult")),
                        f"-only-testing:{TEST_CLASS}/{test}"]
        self.env = dict(os.environ, TEST_RUNNER_BWQA_ID=qa_id)
        self.log, self.test, self.signals, self.passed = log, test, set(), False
        shutil.rmtree(log.with_suffix(".xcresult"), ignore_errors=True)

    def run(self):
        with open(self.log, "w") as out:
            process = subprocess.Popen(self.command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                out.write(line)
                if m := re.search(r"BWQA-SIGNAL (\S+)", line):
                    self.signals.add(m.group(1))
                if re.search(rf"Test Case .*{self.test}.* passed", line):
                    self.passed = True
            process.wait()

    def wait_for(self, signal: str, timeout: float) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline and self.is_alive():
            if signal in self.signals:
                return True
            time.sleep(1)
        return signal in self.signals


def run_step(args, device, test, qa_id, name) -> Step:
    step = Step(args, device, test, qa_id, Path(args.logs) / f"{name}.log")
    step.start()
    return step


def finish(step: Step, name: str) -> bool:
    step.join()
    failure = ""
    if not step.passed:
        failures = [l.strip() for l in open(step.log) if "error:" in l]
        failure = failures[0][-300:] if failures else f"see {step.log}"
    record(name, step.passed, failure)
    return step.passed


def front_matter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"---\n(.*?)\n---", text, re.S)
    fields = {}
    for line in (match.group(1).splitlines() if match else []):
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip().strip('"')
    return fields


def qa_files(qa_id: str, where: Path = QUEUE) -> list[Path]:
    return [p for p in where.glob("*.bw.md") if f"BW QA {qa_id}" in p.read_text(encoding="utf-8", errors="ignore")]


def find(qa_id: str, title: str) -> Path | None:
    for path in qa_files(qa_id):
        if front_matter(path).get("title") == title:
            return path
    return None


def wait_until(description: str, check, timeout: float = 300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(5)
    return None


def rewrite(path: Path, changes: dict) -> None:
    text = path.read_text(encoding="utf-8")
    for key, value in changes.items():
        text = re.sub(rf"^{key}: .*$", f"{key}: {value}", text, count=1, flags=re.M)
    path.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--iphone", required=True)
    parser.add_argument("--ipad", required=True)
    parser.add_argument("--logs", default="/tmp/bwqa")
    parser.add_argument("--id", default=uuid.uuid4().hex[:6])
    parser.add_argument("--delete-only", action="store_true",
                        help="Create a task on the Mac, then run only the watch/rename/delete steps")
    args = parser.parse_args()
    Path(args.logs).mkdir(parents=True, exist_ok=True)
    qa = args.id
    base = f"BW QA {qa}"
    print(f"QA id {qa}; logs in {args.logs}", flush=True)
    if args.delete_only:
        return delete_only(args, qa, base)

    # 1. iPhone creates, edits and completes before the Mac has applied the creation.
    if not finish(run_step(args, args.iphone, "testQA1_CreateEditAndCompleteBeforeTheMacSeesIt", qa, "qa1"), "QA1 iPhone create/edit/complete"):
        return report()
    a = wait_until("A applied", lambda: (p := find(qa, base + " edited")) and front_matter(p).get("status") == "completed" and p)
    record("Mac applied phone create → edit → complete in order (stale placeholder path resolved by ID)", bool(a),
           "" if a else f"files: {[str(p.name) for p in qa_files(qa)]}")
    if not a:
        return report()
    fields = front_matter(a)
    record("Phone-created due date reached the Mac", bool(fields.get("due")), str(fields))
    record("Completion date recorded on the Mac", bool(fields.get("completed")), str(fields))
    record("Exactly one file for the edited task", len([p for p in qa_files(qa) if front_matter(p).get("title", "").startswith(base + " edited")]) == 1)
    c = wait_until("C applied", lambda: find(qa, base + " C"))
    record("Second phone-created task reached the Mac", bool(c))

    # 2. iPad sees it (through the Mac) and reopens it.
    if finish(run_step(args, args.ipad, "testQA2_IPadSeesThePhoneChangesAndReopens", qa, "qa2"), "QA2 iPad sees completed + due, reopens"):
        reopened = wait_until("reopened", lambda: front_matter(a).get("status") == "open" if a.exists() else None)
        record("iPad reopen reached the Mac", bool(reopened), str(front_matter(a)) if a.exists() else "file moved")

    # 3. Mac edits title and stage; iPhone sees it.
    a = find(qa, base + " edited") or a
    rewrite(a, {"title": f'"{base} mac"', "stage": "now"})
    time.sleep(20)
    finish(run_step(args, args.iphone, "testQA3_PhoneSeesTheMacEdit", qa, "qa3"), "QA3 iPhone sees the Mac's title/stage edit")

    # 4. Conflict: iPad edits a stale copy of C while the Mac changes it.
    step = run_step(args, args.ipad, "testQA4_ConflictingEditsBecomeAReviewDraft", qa, "qa4")
    if step.wait_for("QA4-READY", 600) and (c := find(qa, base + " C")):
        rewrite(c, {"title": f'"{base} C mac"'})
    finish(step, "QA4 conflicting iPad edit is refused and offered for review")
    c = find(qa, base + " C mac")
    record("Mac kept its own version in the conflict", bool(c), f"files: {[p.name for p in qa_files(qa)]}")

    # 5 + 6. iPad watches A's page; iPhone deletes A after the Mac renamed its file.
    watch = run_step(args, args.ipad, "testQA5_ADetailPageSaysWhenItsItemIsDeletedElsewhere", qa, "qa5")
    watching = watch.wait_for("QA5-WATCHING", 600)
    delete = run_step(args, args.iphone, "testQA6_DeleteAfterTheMacMovedTheFile", qa, "qa6")
    if watching and delete.wait_for("QA6-READY", 600) and (a := find(qa, base + " mac")):
        moved = a.with_name(f"{base} moved.bw.md")
        a.rename(moved)
        record("Renamed the task's file on the Mac (stale path for the phone)", True, moved.name)
    finish(delete, "QA6 iPhone deletes from the stale path")
    gone = wait_until("A trashed", lambda: find(qa, base + " mac") is None and not any(
        front_matter(p).get("title") == base + " mac" for p in qa_files(qa)), 300)
    record("Deleted task left the Workspace", bool(gone))
    trashed = [p for p in TRASH.glob(f"*{qa}*")]
    record("Deleted task is in the Mac Trash", bool(trashed), ", ".join(p.name for p in trashed))
    finish(watch, "QA5 iPad detail page reports the deletion and blocks edits")

    # 7. The fixture never sends anything, even on a signed-in device.
    finish(run_step(args, args.iphone, "testQA7_TheFixtureNeverReachesTheMac", qa, "qa7"), "QA7 fixture launch without -mobileCloudDisabled")
    time.sleep(60)
    leaked = [p for p in WORKSPACE.glob("*/*.bw.md") if f"{base} fixture" in p.read_text(encoding="utf-8", errors="ignore")]
    record("No fixture item reached the Workspace", not leaked, ", ".join(map(str, leaked)))

    # 8. Clean up the conflict item through the app.
    if finish(run_step(args, args.iphone, "testQA8_CleanUpTheConflictItem", qa, "qa8"), "QA8 delete the conflict item"):
        record("Conflict item left the Workspace", bool(wait_until("C trashed", lambda: not qa_files(qa), 300)))
    return report()


def delete_only(args, qa: str, base: str) -> int:
    """Mac creates a task (written as a file, as Finder or another app would); the iPad
    watches its page while the iPhone deletes it after the Mac renamed it."""
    path = QUEUE / f"{base} mac.bw.md"
    path.write_text(f"""---
better-workspace: 1
id: {uuid.uuid4()}
kind: task
title: "{base} mac"
status: open
stage: now
priority: medium
---
""", encoding="utf-8")
    record("Mac-side task written", True, path.name)
    watch = run_step(args, args.ipad, "testQA5_ADetailPageSaysWhenItsItemIsDeletedElsewhere", qa, "qa5")
    watching = watch.wait_for("QA5-WATCHING", 600)
    record("Mac-created task reached the iPad", watching)
    delete = run_step(args, args.iphone, "testQA6_DeleteAfterTheMacMovedTheFile", qa, "qa6")
    if watching and delete.wait_for("QA6-READY", 600) and path.exists():
        path.rename(path.with_name(f"{base} moved.bw.md"))
    finish(delete, "QA6 iPhone deletes from the stale path")
    gone = wait_until("trashed", lambda: not qa_files(qa), 300)
    record("Deleted task left the Workspace", bool(gone))
    record("Deleted task is in the Mac Trash", bool(list(TRASH.glob(f"*{qa}*"))))
    finish(watch, "QA5 iPad detail page reports the deletion and blocks edits")
    return report()


def report() -> int:
    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed", flush=True)
    for name, _, detail in failed:
        print(f"  FAIL {name} {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
