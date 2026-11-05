#!/usr/bin/env python3
"""Verify a built release through the existing isolated automation gateway.

No installed descriptor, module, display setting or personal app is replaced.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time


def lua_text(value):
    equals = ''
    while ']' + equals + ']' in str(value):
        equals += '='
    return '[' + equals + '[' + str(value) + ']' + equals + ']'


def main():
    source = Path(__file__).resolve().parents[2]
    artifacts = Path(sys.argv[1]).resolve()
    version = (source / 'VERSION').read_text().strip()
    descriptor = json.loads((artifacts / 'codex-obsidian-worker/worker.json').read_text())
    assert descriptor['version'] == version
    app = Path(descriptor['appPath'])
    assert app.is_relative_to(artifacts / 'codex-obsidian-worker')
    with (app / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    assert info['CFBundleShortVersionString'] == version
    assert info['CodexObsidianSourceVersion'] == descriptor['sourceVersion']
    for package in ['obsidian', 'routing']:
        metadata = json.loads((source / package / 'package.json').read_text())
        locked = json.loads((source / package / 'package-lock.json').read_text())
        assert metadata['version'] == locked['version'] == locked['packages']['']['version'] == version

    def evaluate(code):
        result = subprocess.run(['hs', '-t', '5', '-c', code], capture_output=True, text=True,
                                errors='replace', timeout=8)
        lines = [line for line in result.stdout.splitlines() if line.startswith('{')]
        if result.returncode or not lines:
            raise RuntimeError(result.stderr or result.stdout or 'No structured gateway result')
        return json.loads(lines[-1])

    namespace = 'hs._codexWindowReleaseAcceptance'
    initialized = False
    snapshot = None
    try:
        code = 'assert(not ' + namespace + ',"another release acceptance is active");'
        code += namespace + '=assert(loadfile(' + lua_text(source / 'hammerspoon/test/window_safety_acceptance.lua') + '))('
        code += ','.join(map(lua_text, [source, artifacts, '/private/tmp/cuw-release-' + str(os.getpid())])) + ');'
        code += 'print(hs.json.encode(' + namespace + '.snapshot()))'
        snapshot = evaluate(code)
        initialized = True
        deadline = time.monotonic() + 30
        while not snapshot.get('result') and time.monotonic() < deadline:
            time.sleep(0.15)
            snapshot = evaluate('print(hs.json.encode(' + namespace + '.snapshot()))')
        result = snapshot.get('result', {})
        assert result.get('ok') and result.get('backgroundBootstrapInstalled'), snapshot
        assert result['firstObservedScreenUUID'] == result['targetScreenUUID'], snapshot
        assert result['movedAfterCreation'] is False, snapshot
        assert not any(event.get('pid') == snapshot['pid'] for event in snapshot['activations']), snapshot
        task_app = Path(snapshot['workerApp'])
        assert task_app.is_relative_to(artifacts / 'codex-obsidian-worker' / 'tasks'), snapshot
        assert task_app != app, snapshot
        with (task_app / 'Contents/Info.plist').open('rb') as handle:
            task_info = plistlib.load(handle)
        assert task_info['CFBundleIdentifier'] == descriptor['bundleID'] == snapshot['workerBundleID'], snapshot
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(task_app)], check=True)
    finally:
        if initialized:
            closed = evaluate('local r=' + namespace + '.finish();' + namespace + '=nil;print(hs.json.encode(r))')
        else:
            closed = None
    assert snapshot is not None and closed is not None
    deadline = time.monotonic() + 5
    running = True
    while running and time.monotonic() < deadline:
        try:
            os.kill(snapshot['pid'], 0)
            time.sleep(0.1)
        except ProcessLookupError:
            running = False
    assert not running, 'Own release test worker did not stop'
    record = {'version': version, 'descriptor': descriptor, 'appVersion': info['CFBundleShortVersionString'],
              'snapshot': snapshot, 'cleanup': {'ownPID': snapshot['pid'], 'running': running},
              'installedFilesReplaced': False}
    output = source / 'hammerspoon/test/release-build-results.json'
    output.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'version': version, 'appPath': str(app), 'nativeStartupVerified': True,
                      'targetScreenUUID': snapshot['result']['targetScreenUUID'], 'ownWorkerStopped': True}, ensure_ascii=False))


if __name__ == '__main__':
    main()
