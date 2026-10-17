#!/usr/bin/env python3
"""Replay captured optimization scenes and check bounded foliage transmission.

Capture foliage_backlit/frontlit/night, vegetation_shadows, caustics_pool_day/night
and underwater_shafts_morning first. --reference-shaders accepts the 0.2.0 shader
folder and restores only the old work scheduling for air/water comparisons.
Every comparison uses the same GPU recording, not independently captured times.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
venv = ROOT / '.preview/venv/bin/python'
if venv.exists() and Path(sys.prefix).resolve() != venv.parent.parent.resolve():
    os.execv(str(venv), [str(venv), str(Path(__file__).resolve()), *sys.argv[1:]])

import numpy as np
from PIL import Image
from preview.replay import render

FOLIAGE = ('foliage_backlit', 'foliage_frontlit', 'foliage_night')
SCENES = ('caustics_pool_day', 'caustics_pool_night', *FOLIAGE,
          'vegetation_shadows', 'underwater_shafts_morning')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-shaders', type=Path)
    args = parser.parse_args()
    runtime = json.loads((ROOT / '.preview/runtime.json').read_text())
    converter = json.loads((ROOT / '.preview/converter.json').read_text())
    work = ROOT / '.preview/optimization/regressions'
    work.mkdir(parents=True, exist_ok=True)
    baseline = work / 'current'
    capture = render(ROOT, runtime, converter, names=SCENES, output=baseline)
    assert all(scene['changed_pixels'] == 0 for scene in capture['scenes']), 'Current replay differs from native capture'

    def variant(name):
        target = work / (name + '-shaders')
        shutil.copytree(ROOT / 'shaders', target, dirs_exist_ok=True)
        return target

    def pixels(folder, scene):
        return np.asarray(Image.open(folder / (scene + '.png')).convert('RGB'), dtype=np.float32)

    disabled = variant('no-transmission')
    path = disabled / 'settings.glsl'
    source = path.read_text()
    assert '#define FOLIAGE_TRANSLUCENCY 0.4' in source
    path.write_text(source.replace('#define FOLIAGE_TRANSLUCENCY 0.4', '#define FOLIAGE_TRANSLUCENCY 0.0'))
    off = work / 'no-transmission'
    render(ROOT, runtime, converter, names=FOLIAGE, shader_root=disabled, output=off)
    differences = {}
    for scene in FOLIAGE:
        delta = np.abs(pixels(baseline, scene) - pixels(off, scene))
        differences[scene] = {'mean': float(delta.mean()),
                              'pixels': int(np.count_nonzero(delta.max(axis=2) > 0))}
    # The test camera looks +X. Panels are at z=45..49 and z=55..59;
    # the second has an opaque sunward wall. Interior ROIs exclude silhouettes.
    image = pixels(baseline, 'foliage_backlit')
    delta = np.abs(image - pixels(off, 'foliage_backlit'))
    h, w = delta.shape[:2]
    exposed = delta[int(h * 0.41):int(h * 0.72), int(w * 0.27):int(w * 0.42)]
    blocked = delta[int(h * 0.41):int(h * 0.72), int(w * 0.62):int(w * 0.77)]
    assert exposed.mean() > 0.05, 'Thin foliage does not transmit backlight'
    assert blocked.mean() < 0.01, 'Foliage transmission leaks through the solid wall'
    assert differences['foliage_frontlit']['mean'] < differences['foliage_backlit']['mean'], 'Frontlit transmission dominates backlight'
    report = {'native_replay_equal': True, 'foliage_toggle': differences,
              'exposed_panel_mean_delta': float(exposed.mean()),
              'blocked_panel_mean_delta': float(blocked.mean())}

    if args.reference_shaders:
        reference = variant('previous-work')
        for name in ('air_shadow.glsl', 'water_effects.glsl', 'water_lighting.glsl', 'water_reflection.glsl'):
            shutil.copy2(args.reference_shaders / 'lib' / name, reference / 'lib' / name)
        # The old water shader has a fixed eight-step shaft, matching current defaults.
        path = reference / 'lib/air_scattering.glsl'
        path.write_text(path.read_text().replace('coefficient *= densityModulation;',
            'coefficient *= mix(0.98, 1.02, cloudVolumeNoise(cameraPosition / 2048.0).r);'))
        output = work / 'previous-work'
        render(ROOT, runtime, converter, names=SCENES, shader_root=reference, output=output)
        errors = {}
        for scene in SCENES:
            delta = np.abs(pixels(baseline, scene) - pixels(output, scene))
            errors[scene] = {'mean': float(delta.mean()), 'maximum_channel': float(delta.max())}
            # Linear-filter precision can differ slightly from four manual reads.
            assert delta.mean() < 0.10, f'Work scheduling altered scene radiance: {scene}'
        report['previous_work_comparison'] = errors
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
