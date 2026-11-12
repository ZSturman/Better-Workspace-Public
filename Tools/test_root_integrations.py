#!/usr/bin/env python3
"""Targeted native Mac UI checks with an owned loopback server and signed fixture app."""
import http.server
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import threading
import uuid

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--application-only', action='store_true', help='Retest only the application integration')
    options = parser.parse_args()
    evidence = ROOT / 'build' / ('Phase2-RootAcceptance-' + uuid.uuid4().hex)
    evidence.mkdir(parents=True)
    fixture = evidence / 'Fixture.app'
    executable = fixture / 'Contents/MacOS/Fixture'
    executable.parent.mkdir(parents=True)
    (fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.betterworkspace.Phase2.Fixture',
        'CFBundleName': 'Fixture Application', 'CFBundleExecutable': 'Fixture',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.2', 'CFBundleVersion': '1',
        'LSUIElement': True,
    }))
    source = evidence / 'Fixture.m'
    source.write_text('''#import <Cocoa/Cocoa.h>
int main() { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSURL *receipt = [[[NSBundle mainBundle] bundleURL].URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Opened.txt"];
    [@"Opened owned fixture" writeToURL:receipt atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    [NSApp run];
} return 0; }
''')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Cocoa', str(source), '-o', str(executable)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(fixture)], check=True, capture_output=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        count = 0

        def do_GET(self):
            Handler.count += 1
            if self.path == '/start':
                body = '<h1>First fixture page</h1><a href="/second">Next page</a>'
            elif self.path == '/second':
                body = '<h1>Second fixture page</h1><a href="/popup" target="_blank">Popup page</a>'
            else:
                body = '<h1>Popup fixture page</h1><a href="fixture-unsupported://action">Unsupported link</a><p><a href="/error">Server error</a></p>'
            body += f'<p>Visit {Handler.count}</p>'
            payload = ('<!doctype html><html><body>' + body + '</body></html>').encode()
            self.send_response(503 if self.path == '/error' else 200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = os.environ.copy()
    env['TEST_RUNNER_BW_ROOT_WEB_URL'] = f'http://127.0.0.1:{server.server_port}'
    env['TEST_RUNNER_BW_ROOT_APPLICATION_FIXTURE'] = str(fixture)
    command = ['xcodebuild', '-project', 'BetterWorkspace.xcodeproj', '-scheme', 'BetterWorkspace',
               '-derivedDataPath', 'build/UnifiedWorkspaceMac', '-destination', 'platform=macOS,arch=arm64',
               '-only-testing:BetterWorkspaceUITests/WorkspaceRootItemUITests' + ('/testApplicationDetailsLaunchAndUnavailableBundle' if options.application_only else ''),
               '-resultBundlePath', str(evidence / 'Results.xcresult'), 'test']
    print('Owned app/web checks; evidence: ' + str(evidence), flush=True)
    try:
        with (evidence / 'test.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        (evidence / 'receipt.json').write_text(json.dumps({'exitCode': result.returncode, 'webRequests': Handler.count}))
        print('PASSED' if result.returncode == 0 else 'FAILED; inspect test.log', flush=True)
        raise SystemExit(result.returncode)
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
