#!/usr/bin/env python3
"""Run isolated gateway/worker/browser checks, without launching any GUI app."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


def run_checks():
    root = Path(__file__).resolve().parents[2]
    for executable in ('node', 'hs'):
        if not shutil.which(executable):
            raise RuntimeError(f'Missing {executable}; no dependencies were installed')
    node = subprocess.run(
        ['node', '--test', '--test-reporter=tap', 'obsidian/background.test.cjs', 'browser/chrome_work_window.test.mjs',
         *[str(p.relative_to(root)) for p in sorted((root / 'routing').glob('*.test.mjs'))]],
        cwd=root, capture_output=True, text=True, timeout=60,
    )
    counts = {}
    for key in ('tests', 'pass', 'fail', 'skipped'):
        matches = re.findall(r'^# ' + key + r' (\d+)$', node.stdout, re.M)
        if not matches:
            raise RuntimeError(f'Node did not report {key}:\n{node.stdout}\n{node.stderr}')
        counts[key] = int(matches[-1])
    suites = {}
    for name, test_file, module in (
        ('gateway', 'hammerspoon/test/window_gateway.lua', 'hammerspoon/window_gateway.lua'),
        ('sidecar', 'hammerspoon/test/placement_modes.lua', 'hammerspoon/computer_use_sidecar.lua'),
        ('routingApi', 'routing/window_api.test.lua', 'routing/window_api.lua'),
    ):
        code = 'local r=assert(loadfile(' + json.dumps(str(root / test_file), ensure_ascii=False)
        code += '))(' + json.dumps(str(root / module), ensure_ascii=False)
        code += ');print(hs.json.encode(r))'
        lua = subprocess.run(['hs', '-c', code], cwd=root, capture_output=True, text=True, timeout=15)
        candidates = [line for line in lua.stdout.splitlines() if line.startswith('{')]
        if lua.returncode or not candidates:
            raise RuntimeError(f'Isolated {name} checks could not run:\n{lua.stdout}\n{lua.stderr}')
        suites[name] = json.loads(candidates[-1])
    summary = {'node': counts, **suites,
               'passed': counts['pass'] + sum(s['passed'] for s in suites.values()),
               'total': counts['tests'] + sum(s['total'] for s in suites.values()),
               'guiAppsLaunched': False}
    output = root / 'hammerspoon/test/window-safety-rule-results.json'
    output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(f"{summary['passed']}/{summary['total']} isolated checks passed")
    if node.returncode or counts['fail'] or any(s['passed'] != s['total'] for s in suites.values()):
        print(node.stdout, file=sys.stderr)
        print(json.dumps(suites, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(run_checks())
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
