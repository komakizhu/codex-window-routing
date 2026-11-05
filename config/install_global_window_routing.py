#!/usr/bin/env python3
"""Append/remove only this project's routing block, preserving other rules."""
import argparse
from datetime import datetime
from pathlib import Path

BEGIN = '<!-- codex-external-window-routing v1 begin -->'
END = '<!-- codex-external-window-routing v1 end -->'

def update(target: Path, snippet: str, remove: bool = False, *, previous=(), check=False) -> str:
    old = target.read_text() if target.exists() else ''
    block = snippet.strip()
    if BEGIN in old or END in old:
        if old.count(BEGIN) != 1 or old.count(END) != 1:
            raise ValueError('分流规则标记不完整，未改动全局规则')
        start, end = old.index(BEGIN), old.index(END) + len(END)
        if old[start:end] not in {block, *(item.strip() for item in previous)}:
            raise ValueError('现有分流段落已被另外修改，未覆盖')
        new = old[:start] + ('' if remove else block) + old[end:]
    elif remove:
        return 'absent'
    else:
        new = old + ('' if old.endswith('\n\n') else '\n\n') + block + '\n'
    if new == old:
        return 'unchanged'
    if check:
        return 'would-update'
    target.parent.mkdir(parents=True, exist_ok=True)
    backups = target.parent / 'backups'
    backups.mkdir(exist_ok=True)
    backup = backups / ('AGENTS.md.window-routing-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.bak')
    backup.write_text(old)
    target.write_text(new)
    return str(backup)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--remove', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--target', type=Path, default=Path.home() / '.codex/AGENTS.md')
    args = parser.parse_args()
    snippet = Path(__file__).with_name('global-window-routing.md').read_text()
    previous = Path(__file__).with_name('global-window-routing-v0.2.0.md').read_text()
    print(update(args.target, snippet, args.remove, previous=[previous], check=args.check))
