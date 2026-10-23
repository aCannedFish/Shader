#!/usr/bin/env python3
"""Inspect and update the migration ledger, enforcing dependencies and evidence."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / 'docs/migration/state.json'
STATUSES = ('待开始', '进行中', '待验证', '已完成', '受阻')


def source_digest():
    """State changes cannot recursively invalidate their own source fingerprint."""
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    digest = hashlib.sha256()
    for name in sorted(set(names) - {'', 'docs/migration/state.json'}):
        file = ROOT / name
        if file.is_file():
            digest.update(name.encode() + b'\0' + file.read_bytes() + b'\0')
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('status', 'record'))
    parser.add_argument('task', nargs='?')
    parser.add_argument('--status', choices=STATUSES)
    parser.add_argument('--evidence', action='append', default=[])
    parser.add_argument('--note', action='append', default=[])
    parser.add_argument('--next-action')
    args = parser.parse_args()
    state = json.loads(STATE.read_text())
    tasks = {row['id']: row for row in state['tasks']}
    if args.command == 'record':
        if args.task not in tasks or args.status is None:
            parser.error('record requires a known task and --status')
        row = tasks[args.task]
        if args.status in ('进行中', '待验证', '已完成'):
            missing = [name for name in row['depends_on'] if tasks[name]['status'] != '已完成']
            if missing:
                parser.error('Incomplete prerequisites: ' + ', '.join(missing))
        for name in args.evidence:
            if not (ROOT / name).is_file():
                parser.error('Evidence does not exist: ' + name)
        evidence = list(dict.fromkeys(row['evidence'] + args.evidence))
        if args.status == '已完成' and not evidence:
            parser.error('A completed task needs persisted evidence')
        row.update(status=args.status, evidence=evidence,
                   source_commit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                   source_sha256=source_digest())
        row['notes'].extend(args.note)
        row['evidence_sha256'] = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in evidence}
        state['updated'] = datetime.now(ZoneInfo('Asia/Shanghai')).isoformat()
        pending = [row for row in state['tasks'] if row['status'] != '已完成']
        state['current_task'] = pending[0]['id'] if pending else None
        if args.next_action:
            state['next_action'] = args.next_action
        STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n')
    for row in state['tasks']:
        if row['status'] != '待开始':
            print(f"{row['id']} {row['status']} {row['name']}")
    print('Next: ' + str(state['current_task']) + ' ' + state['next_action'])


if __name__ == '__main__':
    main()
