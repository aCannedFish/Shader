#!/usr/bin/env python3
"""Compare shadow-collected model UVs with an independent native rasterization."""
import argparse
import json
from pathlib import Path
import shutil

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', required=True)
    args = parser.parse_args()
    game = ROOT/'.preview'/('game-'+args.run)
    source = game/'screenshots'
    pack = game/'shaderpacks/SimpleShader/shaders'
    output = ROOT/'local-docs/migration/runs'/('P04-uv-'+args.run)
    output.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, output/'screenshots', dirs_exist_ok=True)
    for name in ('capture.log', 'isolation.json'):
        shutil.copy2(ROOT/'.preview'/('captures-'+args.run)/name, output/name)
    for name in ('world-layout.json', 'world-fixture.json', 'world-definitions.json'):
        shutil.copy2(pack/name, output/name)
    fixture = json.loads((pack/'world-fixture.json').read_text())
    fixture_ids = [state['material'] for state in fixture['states']]
    settings = dict(line.split(':',1) for line in (game/'optionsof.txt').read_text().splitlines() if ':' in line)
    scenes = []
    for name in ('migration_shapes', 'migration_atlas_reload'):
        info = json.loads((source/(name+'-world.json')).read_text())
        shape = (info['query_height'], info['query_width'], 4)
        geometry = np.fromfile(source/(name+'-surface-query.raw'), '<f4').reshape(shape)
        uv = np.fromfile(source/(name+'-uv-query.raw'), '<f4').reshape(shape)
        reference = np.fromfile(source/(name+'-uv-reference.raw'), '<f4').reshape(shape)
        selected = np.isin(geometry[...,0], fixture_ids)
        valid = selected & np.all(uv[...,:2] >= 0, axis=-1) & (reference[...,3] > .5)
        error = np.max(abs(uv[...,:2]-uv[...,2:]) * [info['atlas_width'], info['atlas_height']], axis=-1)
        failures = selected & (~valid | (error > .1))
        # Mark raster surface boundaries independently of the world query.
        # Failed edge pixels remain in all overall accuracy/coverage statistics.
        edge = np.zeros(selected.shape, bool)
        for offset in ((0,1),(0,-1),(1,0),(-1,0)):
            other_material = np.roll(geometry[...,0], offset, (0,1))
            other_face = np.roll(reference[...,2], offset, (0,1))
            edge |= (other_material != geometry[...,0]) | (other_face != reference[...,2])
        interior = failures & ~edge
        count = int(np.count_nonzero(selected))
        accuracy = 1 - np.count_nonzero(failures) / max(count,1)
        failed_pixels = np.argwhere(failures)
        np.save(output/(name+'-failed-pixels.npy'), failed_pixels)
        rows = []
        for state in fixture['states']:
            mask = selected & (geometry[...,0] == state['material'])
            if np.any(mask):
                rows.append({'block':state['block'], 'properties':state['properties'],
                             'pixels':int(np.count_nonzero(mask)),
                             'missing':int(np.count_nonzero(mask & ~valid)),
                             'failures':int(np.count_nonzero(mask & failures)),
                             'interior_failures':int(np.count_nonzero(mask & interior))})
        scenes.append({'scene':name, 'pixels':count, 'valid_uvs':int(np.count_nonzero(valid)),
                       'failures_including_edges':int(np.count_nonzero(failures)),
                       'interior_failures':int(np.count_nonzero(interior)),
                       'accuracy_including_edges':float(accuracy),
                       'uv_error_p99_texels':float(np.percentile(error[valid],99)),
                       'raster_reference_matches':bool(np.allclose(uv[...,2:][selected],reference[...,:2][selected],atol=1e-7)),
                       'passed':bool(count > 1000 and accuracy >= .99 and not np.any(interior)
                                     and info.get('atlas_current_resource_match') is True),
                       'materials':rows})
    report = {'passed':all(scene['passed'] and scene['raster_reference_matches'] for scene in scenes),
              'anisotropic_filter_level':settings.get('ofAfLevel'), 'scenes':scenes,
              'thresholds':{'minimum_accuracy_including_edges':.99,'maximum_interior_failures':0,'uv_texel_tolerance':.1},
              'scope':'Fixed native model fixtures; weighted geometry, offsets, animation and layered tint still require separate acceptance'}
    (output/'verification.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({**report, 'scenes':[{k:v for k,v in row.items() if k != 'materials'} for row in scenes]},indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
