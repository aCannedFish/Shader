#!/usr/bin/env python3
"""Check public document links and the source distribution boundary."""
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]


def check_tracked_documents():
    """Local reference material must stay outside the tracked source distribution."""
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT, text=True).split('\0')
    excluded = [name for name in tracked if name.startswith('local-docs/')
                or re.match(r'docs/(?:\d\d-|archive/|benchmarks/)', name)]
    if excluded:
        raise ValueError('Local reference files remain tracked: ' + ', '.join(excluded))


def check_links():
    """Reject missing local targets and links outside the public project tree."""
    documents = [ROOT / name for name in ('README.md', 'CHANGELOG.md', 'THIRD_PARTY.md')]
    documents.extend((ROOT / 'docs').rglob('*.md'))
    count = 0
    for document in documents:
        for name in re.findall(r'\]\(([^)]+)\)', document.read_text()):
            if re.match(r'[a-z]+:', name) or name.startswith('#'):
                continue
            name = unquote(name.split('#', 1)[0].strip('<>'))
            target = (document.parent / name).resolve()
            if not target.is_relative_to(ROOT) or not target.exists():
                raise ValueError(f'Invalid document link: {document.relative_to(ROOT)}: {name}')
            if target.is_relative_to(ROOT / 'local-docs'):
                raise ValueError(f'Non-public document link: {document.relative_to(ROOT)}: {name}')
            count += 1
    return count


def main():
    """Keep both Git source archives and public navigation within project scope."""
    check_tracked_documents()
    count = check_links()
    print(f'Public source boundary and {count} local document links verified')


if __name__ == '__main__':
    main()
