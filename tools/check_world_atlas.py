#!/usr/bin/env python3
"""Archive and validate native atlas samples before and after a resource reload."""
import argparse
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', default='p04-atlas')
    args = parser.parse_args()
    game = ROOT / '.preview' / ('game-' + args.run)
    captures = ROOT / '.preview' / ('captures-' + args.run)
    destination = ROOT / 'local-docs/migration/runs' / ('P04-atlas-' + args.run)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copytree(game / 'screenshots', destination / 'screenshots', dirs_exist_ok=True)
    for name in ('capture.log', 'isolation.json'):
        shutil.copy2(captures / name, destination / name)
    samples = []
    for name in ('migration_shapes', 'migration_atlas_reload'):
        row = json.loads((game / 'screenshots' / (name + '-world.json')).read_text())
        samples.append({
            'scene': name,
            'dimensions': [row.get('atlas_width'), row.get('atlas_height')],
            'passed': row.get('atlas_current_resource_match') is True
                and row.get('without_companion') is True
                and len(row.get('atlas_samples', [])) == 16,
        })
    log = (captures / 'capture.log').read_text(errors='replace')
    # This scene intentionally does not call Shaders.uninit(). Its reload must
    # actually occur; retaining the old texture without a reload is no proof.
    reload_seen = '*** Reloading custom textures ***' in log
    report = {'passed': all(row['passed'] for row in samples) and reload_seen,
              'samples': samples, 'resource_reload_seen': reload_seen,
              'scope': 'J9 prepare samples the live registered block atlas; helper only reads pixels'}
    (destination / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
