#!/usr/bin/env python3
"""Check native world observations against independent, authored fixture points.

This consumes GPU readbacks only. Fixture geometry is created through ordinary
server block edits and never supplies data textures to the target shader.
"""
import argparse
import json
from pathlib import Path
import shutil

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def decode_int(values):
    bits = sum(int(round(float(value))) << (8 * index) for index, value in enumerate(values))
    return bits - 2**32 if bits >= 2**31 else bits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', default='world-coverage')
    args = parser.parse_args()
    game = ROOT / '.preview' / ('game-' + args.run)
    source = game / 'screenshots'
    destination = ROOT / 'local-docs/migration/runs' / ('P03-' + args.run)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination / 'screenshots', dirs_exist_ok=True)
    layout_file = game / 'shaderpacks/SimpleShader/shaders/world-layout.json'
    shutil.copy2(layout_file, destination / 'world-layout.json')
    for filename in ('capture.log', 'isolation.json'):
        shutil.copy2(ROOT / '.preview' / ('captures-' + args.run) / filename, destination / filename)
    contract = json.loads(layout_file.read_text())
    regions = contract['persistent']['regions']
    reports = {}
    failures = []
    for metadata in sorted(source.glob('migration_world_*-world.json')):
        name = metadata.name.removesuffix('-world.json')
        info = json.loads(metadata.read_text())
        arrays = {}
        for region in ('header', 'near_material', 'near_optics', 'far_material', 'far_optics'):
            rectangle = regions[region]
            arrays[region] = np.fromfile(source / (name + '-' + region + '.raw'), dtype='<f4').reshape(
                rectangle['height'], rectangle['width'], 4)
        header = arrays['header'][0]
        near_origin = np.array([decode_int(header[index]) for index in range(2, 5)])
        far_origin = np.array([decode_int(header[index]) for index in range(5, 8)])
        near_shape = np.array(contract['near_shape'])
        actual = np.array(info['actual_camera_readback_only'])
        # This offset is used only to locate authored reference points in the
        # readback. It is never passed to either production or probe GLSL.
        actual_origin = np.floor(actual / 4).astype(int) * 8 - near_shape // 2
        offset = (actual_origin - near_origin) // 2

        def sample(point, field, near):
            shape = np.array(contract['near_shape'] if near else contract['far_shape'])
            rate = 2 if near else 1
            origin = near_origin if near else far_origin
            cell = (np.array(point) + np.array([0, 120, 0]) - offset) * rate - origin
            if np.any(cell < 0) or np.any(cell >= shape):
                raise ValueError('Reference point outside promised coverage: ' + str(point))
            x, y, z = cell
            pixel = (int(x + z % 8 * shape[0]), int(y + z // 8 * shape[1]))
            return arrays[('near_' if near else 'far_') + field][pixel[1], pixel[0]]

        points = ([((2530,83,2536), 2, None), ((2542,83,2536), 2, None),
                   ((2536,83,2530), 2, None), ((2536,83,2542), 2, None)]
                  if name.endswith('room') else
                  [((2494,83,2500), 2, 'red'), ((2506,83,2500), 2, 'blue'),
                   ((2500,83,2494), 2, None), ((2500,83,2506), 4, None),
                   ((2503,80,2503), 3, None), ((2500,80,2500), 2, None),
                   ((2500,85,2500), 0, None)])
        samples = []
        for point, expected, hue in points:
            for near in (True, False):
                optics = sample(point, 'optics', near)
                material = sample(point, 'material', near)
                passed = int(optics[3]) == expected
                if hue == 'red':
                    passed &= material[0] > material[1] * 2 and material[0] > material[2] * 2
                if hue == 'blue':
                    passed &= material[2] > material[0] * 2
                row = {'point': point, 'field': 'near' if near else 'far', 'expected_state': expected,
                       'optics': optics.tolist(), 'material': material.tolist(), 'passed': bool(passed)}
                samples.append(row)
                if not passed:
                    failures.append({'scene': name, **row})
        if not name.endswith('room'):
            for point in ((2460,83,2500),(2540,83,2500),(2500,83,2460),(2500,83,2540)):
                optics = sample(point, 'optics', False)
                material_id = int(optics[0] + optics[1] * 256)
                passed = int(optics[3]) == 2 and material_id == 301
                row = {'point': point, 'field': 'far', 'expected_material': 301,
                       'optics': optics.tolist(), 'passed': passed}
                samples.append(row)
                if not passed:
                    failures.append({'scene': name, **row})
        reports[name] = {'native_passed': info['passed'], 'samples': samples,
                         'offset_readback_only': offset.tolist(),
                         'unknown_near': int(np.count_nonzero(arrays['near_optics'][...,3] == 0)),
                         'unknown_far': int(np.count_nonzero(arrays['far_optics'][...,3] == 0))}
    if len(reports) != 5:
        failures.append({'missing_scenes': 5 - len(reports)})
    output = {'passed': not failures, 'scenes': reports, 'failures': failures,
              'scope': 'Native fixed scene observations; absence is unknown, not certified air'}
    (destination / 'verification.json').write_text(json.dumps(output, indent=2) + '\n')
    if failures:
        print(json.dumps(failures, indent=2))
        raise SystemExit(1)
    print('All four view directions, screen-external markers and sealed-room surfaces passed')


if __name__ == '__main__':
    main()
