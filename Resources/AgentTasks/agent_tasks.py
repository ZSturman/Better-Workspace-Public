#!/usr/bin/env python3
"""Better Workspace CLI bridge. Private run files; never edits task records itself."""
import concurrent.futures
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
import urllib.parse
import urllib.error

PROVIDERS = ('claude', 'codex', 'antigravity', 'lmstudio')

class BlockedRun(ValueError):
    """A provider policy prevented work; this must never imply completion."""

def executable(name):
    candidates = [shutil.which(name), str(Path.home() / '.local/bin' / name),
                  '/opt/homebrew/bin/' + name, '/usr/local/bin/' + name]
    if name == 'codex':
        candidates += ['/Applications/Codex.app/Contents/Resources/codex',
                       '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex']
    return next((p for p in candidates if p and os.access(p, os.X_OK) and Path(p).is_file()), None)

def capture(args, timeout=20, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)

def codex_models(binary):
    p = subprocess.Popen([binary, 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)
    try:
        for message in [dict(id=1, method='initialize', params={'clientInfo': {'name': 'better_workspace', 'version': '1.0'}}),
                        dict(method='initialized'), dict(id=2, method='model/list', params={})]:
            p.stdin.write(json.dumps(message) + '\n')
            p.stdin.flush()
        deadline = time.monotonic() + 12
        selector = selectors.DefaultSelector()
        selector.register(p.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            if not selector.select(.2):
                continue
            line = p.stdout.readline()
            if not line:
                break
            obj = json.loads(line)
            if obj.get('id') == 2:
                if 'error' in obj:
                    raise ValueError(str(obj['error']))
                return [{'id': m['model'], 'label': m.get('displayName', m['model'])}
                        for m in obj['result']['data'] if not m.get('hidden')]
        raise ValueError('Model discovery timed out. Use the provider default or an exact model ID.')
    finally:
        p.terminate()
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()

def endpoint_root(endpoint):
    parsed = urllib.parse.urlparse(endpoint)
    if (parsed.scheme not in ('http', 'https') or parsed.hostname not in ('localhost', '127.0.0.1', '::1')
            or parsed.path.rstrip('/') != '/v1' or parsed.username or parsed.password or parsed.query or parsed.fragment):
        raise ValueError('LM Studio endpoint must be a loopback URL ending in /v1.')
    return endpoint.rstrip('/')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise ValueError('LM Studio redirects are not allowed.')

def local_json(url):
    with urllib.request.build_opener(NoRedirect).open(url, timeout=5) as r:
        data = json.loads(r.read(1024 * 1024))
    return data

def local_models(endpoint):
    root = endpoint_root(endpoint)
    data = local_json(root + '/models')
    models = {m['id']: dict(id=m['id'], label=m['id'] + ' · readiness unknown')
              for m in data.get('data', []) if 'embed' not in m.get('id', '').lower()}
    try:
        native = local_json(root[:-3] + '/api/v1/models')
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        # Older servers expose only the compatibility API. Do not invent readiness.
        return list(models.values())
    for model in native.get('models', []):
        key = model.get('key')
        if model.get('type') != 'llm' or not key:
            continue
        instances = model.get('loaded_instances', [])
        loaded = {instance['id']: instance for instance in instances if instance.get('id')}
        for identifier in {key, *loaded}:
            if identifier not in models:
                continue
            instance = loaded.get(identifier)
            context = instance.get('config', {}).get('context_length') if instance else None
            problems = []
            if instance is None:
                problems.append('Load this model in LM Studio before submitting; Better Workspace does not load or download models.')
            if model.get('capabilities', {}).get('trained_for_tool_use') is False:
                problems.append('This model is not trained for agent tool use. Select a tool-capable model.')
            if isinstance(context, int) and context < 32768:
                problems.append(f'This model is loaded at {context} tokens. Reload with at least 32768 tokens for agent tools.')
            status = f'{context // 1024}K context' if isinstance(context, int) else 'loaded' if instance else 'not loaded'
            models[identifier] = dict(id=identifier, label=model.get('display_name', key) + ' · ' + status,
                                      problem=' '.join(problems))
    return list(models.values())

def local_preflight(request):
    selected = next((m for m in local_models(request['endpoint']) if m['id'] == request.get('model')), None)
    if selected is None:
        raise BlockedRun('Selected LM Studio model is unavailable. Load it and refresh providers.')
    if selected.get('problem'):
        raise BlockedRun(selected['problem'])

def usage(provider):
    binary = executable('codexbar')
    if not binary:
        return 'Usage unavailable — install CodexBar CLI to show limits.', False
    args = [binary, 'usage', '--provider', provider, '--format', 'json', '--web-timeout', '8']
    if provider in ('claude', 'codex'):
        args += ['--source', 'cli']
    try:
        result = capture(args, timeout=15)
        payload = json.loads(result.stdout)
        entry = payload[0] if isinstance(payload, list) else payload
        if entry.get('error'):
            return 'Usage unavailable: ' + str(entry['error'])[:240], False
        windows = entry.get('usage', {})
        labels, exhausted = [], False
        extra = windows.get('extraRateWindows', [])
        named = [(w.get('window'), w.get('title', w.get('id', 'Limit'))) for w in extra]
        if not named:
            named = [(windows.get(key), name) for key, name in [('primary', 'Session'), ('secondary', 'Weekly'), ('tertiary', 'Other')]]
        for window, name in named:
            if not window or 'usedPercent' not in window:
                continue
            remaining = max(0, 100 - window['usedPercent'])
            exhausted |= remaining == 0
            reset = window.get('resetDescription') or window.get('resetsAt')
            labels.append(f'{name}: {remaining:.1f}% remaining' + (f' ({reset})' if reset else ''))
        credits = entry.get('credits', {})
        if credits.get('balanceReadSucceeded') and credits.get('remaining') is not None:
            labels.append(f"Extra credits: {credits['remaining']}")
        return ' · '.join(labels) or 'Usage unavailable — CodexBar returned no limits.', exhausted
    except Exception as e:
        return 'Usage unavailable: ' + str(e)[:200], False

def discover_provider(provider, endpoint):
    binary = executable('codex' if provider == 'lmstudio' else 'agy' if provider == 'antigravity' else provider)
    info = dict(id=provider, available=bool(binary), models=[], usage='Local inference; no cloud credits.' if provider == 'lmstudio' else '', exhausted=False, problem='')
    if not binary:
        info['problem'] = ('Codex CLI is required to run LM Studio as a coding agent.' if provider == 'lmstudio' else 'CLI not installed or not found on PATH.')
    try:
        if provider == 'lmstudio':
            info['models'] = local_models(endpoint)
            info['available'] = bool(binary and info['models'])
        elif binary and provider == 'codex':
            info['models'] = codex_models(binary)
        elif binary and provider == 'antigravity':
            result = capture([binary, 'models'])
            info['models'] = [{'id': parts[0], 'label': parts[-1]} for line in result.stdout.splitlines()
                              if len(parts := line.split('\t')) == 2]
        elif binary and provider == 'claude':
            # Claude has no model-list CLI. Aliases resolve in Claude; exact IDs remain editable.
            info['models'] = [{'id': k, 'label': v} for k, v in [('haiku', 'Haiku'), ('sonnet', 'Sonnet'), ('opus', 'Opus'), ('claude-opus-4-5', 'Opus 4.5 (availability checked on run)')]]
    except Exception as e:
        info['problem'] = str(e)[:300]
        if provider == 'lmstudio':
            info['available'] = False
    if provider != 'lmstudio':
        info['usage'], info['exhausted'] = usage(provider)
    return info

def schema(tasks):
    return {'type': 'object', 'properties': {
        'completed': {'type': 'array', 'items': {'type': 'object', 'properties': {
            'id': {'type': 'string', 'enum': [t['id'] for t in tasks] or ['no-task']},
            'evidence': {'type': 'string'}}, 'required': ['id', 'evidence'], 'additionalProperties': False}},
        'summary': {'type': 'string'}}, 'required': ['completed', 'summary'], 'additionalProperties': False}

def prompt_for(request, tasks, prior):
    order = ('Execute these tasks strictly in the displayed order. Do not start a later task until the earlier task succeeds. Stop on a blocked or failed task.'
             if request['sequential'] else 'These tasks have no required execution order. Choose an efficient order; concurrent work is optional.')
    return ('You are working on a user-submitted Better Workspace project task batch.\n'
            + order + '\nProject directory: ' + request['projectPath'] + '\n'
            'Respect project instructions. Do not inspect or modify foreign metadata (.project-core, _audit). '
            'Do not edit Better Workspace task records or send remote Notion changes. '
            'Perform the requested work and verify it. Report only tasks actually completed successfully, '
            'using exact task IDs and concrete verification evidence. Do not claim success on denied tools or unperformed work.\n'
            + 'Already completed in this batch: ' + json.dumps(prior) + '\n'
            + 'User instructions:\n' + request['instructions'] + '\nSelected tasks:\n'
            + json.dumps([{k: t[k] for k in ('id', 'title', 'body')} for t in tasks], ensure_ascii=False)
            + '\nYour final answer MUST be only a JSON object conforming to this schema, without Markdown or explanatory prose: '
            + json.dumps(schema(tasks)) + '\nUse completed: [] if the work or verification was blocked.')

def command(request, tasks, folder, index):
    provider = request['provider']
    binary = executable('codex' if provider == 'lmstudio' else 'agy' if provider == 'antigravity' else provider)
    if not binary:
        raise ValueError('Provider CLI is unavailable.')
    spec = schema(tasks)
    model, effort = request.get('model', ''), request.get('effort', '')
    final = folder / f'final-{index}.json'
    if provider in ('codex', 'lmstudio'):
        spec_path = folder / f'schema-{index}.json'
        spec_path.write_text(json.dumps(spec))
        args = [binary, 'exec', '--skip-git-repo-check', '--sandbox', 'workspace-write', '--color', 'never',
                '--output-schema', str(spec_path), '-o', str(final)]
        args += ['-c', 'sandbox_workspace_write.network_access=' + ('true' if request.get('networkAccess') else 'false')]
        if provider == 'lmstudio':
            root = endpoint_root(request['endpoint'])
            args += ['--oss', '--local-provider', 'lmstudio']
        if effort and provider == 'codex':
            args += ['-c', 'model_reasoning_effort=' + json.dumps(effort)]
        if model:
            args += ['--model', model]
        args += ['-']
    else:
        if provider == 'antigravity' and request.get('interactive', True):
            args = [binary, '--mode', 'accept-edits', '--add-dir', str(folder)]
            if model:
                args += ['--model', model]
            if effort:
                args += ['--effort', effort]
            return args, final
        args = [binary] + (['-p'] if provider == 'claude' else []) + ['--output-format', 'json', '--json-schema', json.dumps(spec)]
        args += ['--permission-mode', 'acceptEdits'] if provider == 'claude' else ['--mode', 'accept-edits']
        if model:
            args += ['--model', model]
        if effort:
            args += ['--effort', effort]
    return args, final

def completion_report(provider, output, final, interactive=False):
    if provider in ('codex', 'lmstudio') or interactive:
        try:
            obj = json.loads(final.read_text())
        except (ValueError, OSError) as e:
            raise ValueError('The model did not return a valid task completion report. No tasks were marked complete. Use a coding/tool-capable model and inspect the run logs.') from e
    else:
        envelope = json.loads(output)
        denied = envelope.get('denied_actions') or envelope.get('permission_denials')
        if denied:
            actions = ', '.join(str(a.get('action') or a.get('tool_name') or a.get('display_name') or 'tool') for a in denied)
            raise BlockedRun('Provider permission blocked: ' + actions + '. No tasks in this response were marked complete. '
                             'For Antigravity, enable Review command approvals in Terminal and approve the specific operation there. '
                             'Headless mode requires existing scoped provider allow rules.')
        if envelope.get('is_error') or envelope.get('status', 'SUCCESS') != 'SUCCESS':
            raise ValueError(str(envelope.get('error') or envelope.get('result') or envelope.get('status')))
        obj = envelope.get('structured_output')
        if obj is None:
            response = envelope.get('response', envelope.get('result', ''))
            if not response or not response.strip():
                raise BlockedRun('Provider returned no completion report. No tasks were marked complete. Check the run logs for permission, login or usage blockers.')
            try:
                obj = json.loads(response)
            except ValueError as e:
                raise ValueError('Provider returned an invalid completion report. No tasks were marked complete. Inspect the run logs.') from e
    if not isinstance(obj, dict) or not isinstance(obj.get('completed'), list) or not isinstance(obj.get('summary'), str):
        raise ValueError('The model did not return a valid task completion report. No tasks were marked complete. Use a coding/tool-capable model and inspect the run logs.')
    return obj

def atomic_json(path, obj):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(obj, ensure_ascii=False))
    os.chmod(temp, 0o600)
    temp.replace(path)

def validated_completed(report, tasks, sequential):
    ids = [t['id'] for t in tasks]
    completed = report['completed']
    found = [c.get('id') for c in completed if isinstance(c, dict)]
    if (len(found) != len(completed) or len(found) != len(set(found)) or not set(found).issubset(ids)
            or any(not isinstance(c.get('evidence'), str) or not c['evidence'].strip() for c in completed)):
        raise ValueError('Completion IDs or evidence were invalid; no tasks in this response were completed.')
    if sequential and found != ids[:len(found)]:
        raise ValueError('Completion report violates the selected order.')
    return completed

def interactive_run(args, project, final, tasks, sequential, log_path, timeout):
    """Give the provider the actual foreground TTY, while monitoring its completion file."""
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise BlockedRun('Interactive Antigravity requires Terminal. Submit from Better Workspace or run the launcher in a Terminal window.')
    prepare_final(final)
    foreground = os.tcgetpgrp(sys.stdin.fileno())
    def foreground_child():
        os.setpgrp()
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        os.tcsetpgrp(sys.stdin.fileno(), os.getpgrp())
        signal.signal(signal.SIGTTOU, signal.SIG_DFL)
    child = subprocess.Popen(args + ['--log-file', str(log_path)], cwd=project, preexec_fn=foreground_child)
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            if final.exists():
                if final.is_symlink() or final.stat().st_size > 4_000_000:
                    raise ValueError('Invalid interactive completion file.')
                try:
                    report = completion_report('antigravity', '', final, interactive=True)
                except ValueError:
                    # A file-edit tool may create the file before finishing its contents.
                    report = None
                if report is not None:
                    validated_completed(report, tasks, sequential)
                    return report
            if child.poll() is not None:
                raise BlockedRun('Antigravity exited before saving a valid completion report. No tasks were marked complete.')
            time.sleep(.2)
        raise BlockedRun('Antigravity timed out waiting for completion or a Terminal approval. No tasks in this response were marked complete.')
    finally:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL); child.wait()
        previous = signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        try:
            os.tcsetpgrp(sys.stdin.fileno(), foreground)
        finally:
            signal.signal(signal.SIGTTOU, previous)


def prepare_final(final):
    # Relaunching a blocked command must not accept a previous agent's report.
    if final.is_symlink():
        raise ValueError('Invalid completion file path.')
    if final.exists():
        final.replace(final.with_name('previous-' + final.name))

def run(request_path):
    folder = request_path.parent
    request = json.loads(request_path.read_text())
    project = Path(request['projectPath'])
    receipt = dict(runID=request['runID'], state='running', completed=[], summary='Starting agent…')
    atomic_json(folder / 'receipt.json', receipt)
    # One invocation per task gives incremental receipts and hard sequential execution.
    groups = [[t] for t in request['tasks']] if request['sequential'] and request['tasks'] else [request['tasks']]
    try:
        if not project.is_dir() or project.resolve() != project.absolute():
            raise ValueError('Project is unavailable or uses a symlink path.')
        if request['provider'] not in PROVIDERS:
            raise ValueError('Unknown provider.')
        if request['provider'] == 'lmstudio':
            local_preflight(request)
        for index, tasks in enumerate(groups):
            args, final = command(request, tasks, folder, index)
            prompt = prompt_for(request, tasks, receipt['completed'])
            print(f"\nBetter Workspace: {request['provider']} · batch {index + 1}/{len(groups)}", flush=True)
            if request['provider'] == 'antigravity' and request.get('interactive', True):
                receipt['summary'] = 'Antigravity is working in Terminal. Review any specific command approval prompts there.'
                atomic_json(folder / 'receipt.json', receipt)
                prompt += ('\nThis is an interactive run: request approval for commands when needed. '
                           'Your FINAL action after performing and verifying the tasks is to write only the JSON completion report to '
                           + str(final) + '. This private run folder is an explicitly added workspace. '
                           'Do not edit request.json, receipt.json or ack.json. Write a report with completed: [] if blocked. '
                           'Use this schema: ' + json.dumps(schema(tasks)))
                args += ['--prompt-interactive=' + prompt]
                report = interactive_run(args, project, final, tasks, request['sequential'],
                                         folder / f'interactive-{index}.log', request.get('timeoutSeconds', 3600))
                completed = validated_completed(report, tasks, request['sequential'])
                receipt['completed'].extend(completed); receipt['summary'] = report['summary']
                atomic_json(folder / 'receipt.json', receipt)
                if request['sequential'] and len(completed) != len(tasks):
                    receipt['state'] = 'blocked'
                    break
                continue
            prepare_final(final)
            environment = os.environ.copy()
            if request['provider'] == 'lmstudio':
                environment['CODEX_OSS_BASE_URL'] = endpoint_root(request['endpoint'])
            stdin_prompt = prompt
            if request['provider'] == 'antigravity':
                args += ['--print=' + prompt]
                stdin_prompt = None
            output_path = folder / f'output-{index}.log'
            error_path = folder / f'error-{index}.log'
            with output_path.open('w') as output, error_path.open('w') as errors:
                child = subprocess.Popen(args, cwd=project, stdin=subprocess.PIPE, stdout=output, stderr=errors,
                                         text=True, start_new_session=True, env=environment)
                try:
                    child.communicate(stdin_prompt, timeout=request.get('timeoutSeconds', 3600))
                except BaseException:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    raise
            output = output_path.read_text(errors='replace')
            errors = error_path.read_text(errors='replace')
            print(errors[-6000:] + output[-12000:], flush=True)
            if child.returncode:
                raise ValueError(f'Provider exited {child.returncode}: ' + (errors + output)[-1500:])
            report = completion_report(request['provider'], output, final)
            completed = validated_completed(report, tasks, request['sequential'])
            receipt['completed'].extend(completed)
            receipt['summary'] = report['summary']
            atomic_json(folder / 'receipt.json', receipt)
            if request['sequential'] and len(completed) != len(tasks):
                receipt['state'] = 'blocked'
                break
        else:
            receipt['state'] = 'finished' if len(receipt['completed']) == len(request['tasks']) else 'blocked'
    except BaseException as e:
        receipt['state'] = 'blocked' if isinstance(e, BlockedRun) else 'failed'
        receipt['summary'] = str(e) or 'Run interrupted.'
        if any(word in receipt['summary'].lower() for word in ('quota', 'rate limit', 'usage limit', 'credit', 'resource_exhausted', 'limit reached')):
            receipt['summary'] = 'Provider credits or usage limit reached. ' + receipt['summary']
    atomic_json(folder / 'receipt.json', receipt)
    print('\n' + receipt['state'].upper() + ': ' + receipt['summary'], flush=True)
    return 0 if receipt['state'] == 'finished' else 1

if __name__ == '__main__':
    if sys.argv[1] == 'discover':
        endpoint = sys.argv[2] if len(sys.argv) > 2 else 'http://127.0.0.1:1234/v1'
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            print(json.dumps(list(pool.map(lambda p: discover_provider(p, endpoint), PROVIDERS))))
    elif sys.argv[1] == 'run':
        sys.exit(run(Path(sys.argv[2]).absolute()))
