#!/usr/bin/env python3
"""Exercise packaged service with its offline runtime in an owned fixture, never launchd."""
import argparse
import json
import os
import platform
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--report', type=Path, required=True)
parser.add_argument('--architecture', choices=['arm64', 'x86_64'], default=platform.machine())
parser.add_argument('--allow-legacy', action='store_true', help='Only for historical packages that require a system Python.')
parser.add_argument('--isolated-launchd', action='store_true', help='Run the bounded fixture as a unique, temporary launchd job; never install the personal service label.')
args = parser.parse_args()
source = args.app.resolve() / 'Contents/Resources/BackgroundService'
assert (source / 'workspace_watcher/core_runtime.py').is_file()
root = Path(tempfile.mkdtemp(prefix='bw-release-service-'))
home = root / 'installation'; home.mkdir()
workspace = root / 'Workspace'
for area in ['Projects/Release fixture', 'Ideas/Release fixture', 'Logs', 'To Do']:
    (workspace / area).mkdir(parents=True, exist_ok=True)
shutil.copytree(source / 'workspace_watcher', home / 'app/workspace_watcher')
for name in ['run.sh', 'requirements.txt']:
    shutil.copy2(source / name, home / name)
shutil.copy2(source / 'rules.default.toml', home / 'rules.toml')
(home / 'config.toml').write_text(f'''[workspace_watcher]
workspace_root = "{workspace}"
rules_file = "rules.toml"
[workspace_watcher.storage]
database = "Logs/workspace-watcher/core.db"
[workspace_watcher.intent_folders]
excluded_roots = ["Logs/workspace-watcher"]
[workspace_watcher.intent_folders.declared]
"Ideas" = "Ideas"
[workspace_watcher.projects]
write_documents = false
[workspace_watcher.notion]
enabled = false
''')
runtime = source / 'PythonRuntime' / args.architecture / 'python'
if runtime.is_dir():
    shutil.copytree(runtime, home / 'runtime', symlinks=True)
    python = home / 'runtime/bin/python3'
    mode = 'bundled offline runtime'
else:
    if not args.allow_legacy:
        raise SystemExit('Package has no embedded offline runtime. --allow-legacy is only for historical candidate 3.')
    subprocess.run([sys.executable, '-m', 'venv', str(home / 'venv')], check=True, capture_output=True)
    python = home / 'venv/bin/python'
    subprocess.run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check', '-r', str(home / 'requirements.txt')], check=True, capture_output=True, timeout=120)
    mode = 'legacy system Python virtualenv'
# Exercise the installed launcher without starting the fixed per-user launchd service.
subprocess.run([str(home / 'run.sh'), '--help'], check=True, capture_output=True, timeout=15)
probe = root / 'probe.py'
probe.write_text('''import json,sys,threading,urllib.request
from pathlib import Path
from workspace_watcher.core_config import load_core_config
from workspace_watcher.core_runtime import CoreRuntime
from workspace_watcher.core_api import serve
home=Path(sys.argv[1]).resolve();config=load_core_config(home/'config.toml')
assert config.workspace_root.is_relative_to(home.parent)
def request(base,method,path,body=None):
 data=json.dumps(body).encode() if body is not None else None
 req=urllib.request.Request(base+path,data=data,method=method,headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=10) as response:return json.load(response)['data']
def start():
 runtime=CoreRuntime(config);runtime.start()
 server=serve(config,port=0,runtime=runtime)
 thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
 return runtime,server,thread,'http://127.0.0.1:'+str(server.server_port)
def stop(runtime,server,thread):
 server.shutdown();thread.join(timeout=5);server.server_close();runtime.stop()
runtime,server,thread,base=start()
try:
 health=request(base,'GET','/v1/health');assert health['state']=='running',health
 idea=request(base,'POST','/v1/ideas/register',{'path':str(config.workspace_root/'Ideas/Release fixture')})
 updated=request(base,'PATCH','/v1/ideas/'+idea['id'],{'planning':{'priority':4,'ratings':{'qualityOfLife':4},'potential':'project','needsSetup':False}})
 assert updated['planning']['priority']==4,updated
 idea_id=idea['id']
finally:stop(runtime,server,thread)
runtime,server,thread,base=start()
try:
 restored=request(base,'GET','/v1/ideas/'+idea_id)
 assert restored['planning']['priority']==4 and restored['planning']['ratings']['qualityOfLife']==4,restored
 assert not list(config.workspace_root.rglob('watcher.item.toml'))
 print(json.dumps({'packaged_service':'passed','fresh_runtime_and_launcher':'passed','runtime_health':'passed','private_idea_save_restart_readback':'passed','sidecars_created':False,'launchd_or_personal_service_changed':False,'listener':'OS-assigned loopback port'},indent=2))
finally:stop(runtime,server,thread)
''')
environment = dict(os.environ, PYTHONPATH=str(home / 'app'), PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1', PYTHONSAFEPATH='1')
if args.isolated_launchd:
    import plistlib
    label = 'com.zacharysturman.BetterWorkspace.release-verification.' + str(uuid.uuid4())
    domain = 'gui/' + str(os.getuid())
    stdout = root / 'launchd.stdout.json'
    stderr = root / 'launchd.stderr.log'
    definition = root / (label + '.plist')
    definition.write_bytes(plistlib.dumps({
        'Label': label, 'ProgramArguments': [str(python), str(probe), str(home)],
        'WorkingDirectory': str(home), 'EnvironmentVariables': {
            key: environment[key] for key in ['PYTHONPATH', 'PYTHONNOUSERSITE', 'PYTHONDONTWRITEBYTECODE', 'PYTHONSAFEPATH']
        }, 'RunAtLoad': True, 'ProcessType': 'Background',
        'StandardOutPath': str(stdout), 'StandardErrorPath': str(stderr),
    }))
    subprocess.run(['launchctl', 'bootstrap', domain, str(definition)], check=True, capture_output=True, timeout=15)
    try:
        deadline = time.monotonic() + 75
        while True:
            status = subprocess.run(['launchctl', 'print', domain + '/' + label], capture_output=True, text=True, timeout=5)
            (root / 'launchd.status.txt').write_text(status.stdout + status.stderr)
            exited = re.search(r'last exit code = (\d+)', status.stdout)
            if status.returncode or (exited and 'state = running' not in status.stdout):
                code = int(exited.group(1)) if exited else 1
                result = subprocess.CompletedProcess([], code, stdout.read_text() if stdout.exists() else '', stderr.read_text() if stderr.exists() else status.stderr)
                break
            if time.monotonic() >= deadline:
                raise TimeoutError('Isolated launchd fixture did not complete within 75 seconds')
            time.sleep(0.25)
    finally:
        subprocess.run(['launchctl', 'bootout', domain + '/' + label], check=True, capture_output=True, timeout=15)
else:
    result = subprocess.run([str(python), str(probe), str(home)], env=environment, capture_output=True, text=True, timeout=75)
if result.returncode:
    print(result.stderr[-2500:], file=sys.stderr)
    print('Owned fixture diagnostics:', root, file=sys.stderr)
    raise SystemExit(result.returncode)
report = json.loads(result.stdout)
if args.isolated_launchd:
    report['launchd_or_personal_service_changed'] = 'Only a unique temporary verification job; removed after completion'
    report['isolated_launchd_run_at_load'] = 'passed'
    report['personal_launchd_service_changed'] = False
    report['clean_user_login_installation'] = 'not verified by this isolated job'
report.update(runtime_mode=mode, architecture=args.architecture)
args.report.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
print('Owned fixture retained:', root)
