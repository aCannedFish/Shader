#!/usr/bin/env python3
"""Check actual bloom GLSL on macOS OpenGL, including odd-sized viewports.

Requires NumPy and Pillow in the preview venv. No game or capture is needed.
Use --baseline-shaders for a pre-optimization shader directory to measure the
old two-pass filter on the same GPU input. Timings cover bloom plus reconstruction,
not the Minecraft frame, and deliberately exclude compilation and texture upload.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
venv = ROOT / '.preview/venv/bin/python'
if venv.exists() and Path(sys.prefix).resolve() != venv.parent.parent.resolve():
    os.execv(str(venv), [str(venv), str(Path(__file__).resolve()), *sys.argv[1:]])

import numpy as np
from PIL import Image
from preview.source import expand
from check_glsl import FORMAT_TOKENS


def shaders(folder, source_root, resolution, legacy=False, disabled=False):
    """Wrap the repository kernel in minimal stages, preserving its GLSL maths."""
    source = expand(source_root / 'lib/bloom.glsl', source_root)
    source = re.sub(r'(#define BLOOM_RESOLUTION) \d+', rf'\g<1> {resolution}', source)
    if disabled:
        source = source.replace('#define ENABLE_BLOOM 1', '#define ENABLE_BLOOM 0')
    header = '#version 150\n' + '\n'.join(f'#define {name} 0' for name in FORMAT_TOKENS)
    header += '\n' + source.replace('texture2D(', 'texture(')
    header += '\nuniform sampler2D source;\nout vec4 result;\n'
    full_uv = 'gl_FragCoord.xy / vec2(viewWidth, viewHeight)'
    scale = 1.0 if resolution else 0.5
    if legacy:
        stages = [(1.0, f'filterBloom(source, {full_uv}, vec2(1, 0), true)'),
                  (1.0, f'filterBloom(source, {full_uv}, vec2(0, 1), false)'),
                  (1.0, f'texture(source, {full_uv}).rgb')]
    else:
        uv = 'gl_FragCoord.xy / bloomSize()'
        stages = [(scale, f'prefilterBloom(source, {uv})'),
                  (scale, f'filterBloom(source, {uv}, vec2(1, 0))'),
                  (scale, f'filterBloom(source, {uv}, vec2(0, 1))'),
                  (1.0, f'texture(source, bloomUv({full_uv})).rgb')]
    arguments = []
    for index, (viewport, expression) in enumerate(stages):
        path = folder / f'{index}.frag'
        path.write_text(header + '\nvoid main() { result = vec4(' + expression + ', 1); }\n')
        arguments.extend([str(viewport), str(path)])
    return arguments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-shaders', type=Path)
    args = parser.parse_args()
    work = ROOT / '.preview/bloom-verification'
    work.mkdir(parents=True, exist_ok=True)
    executable = work / 'bloom_probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(executable)], check=True)
    variants = {}
    for name, resolution, disabled in [('half', 0, False), ('full', 1, False), ('off', 0, True)]:
        folder = work / name
        folder.mkdir(exist_ok=True)
        variants[name] = shaders(folder, ROOT / 'shaders', resolution, disabled=disabled)
    if args.baseline_shaders:
        folder = work / 'baseline'
        folder.mkdir(exist_ok=True)
        variants['baseline'] = shaders(folder, args.baseline_shaders.resolve(), 1, legacy=True)

    def render(name, field, label):
        height, width, _ = field.shape
        original = work / 'input.f32'
        target = work / name / (label + '.f32')
        field.astype('<f4').tofile(original)
        output = subprocess.check_output([str(executable), str(width), str(height), str(original),
                                          str(target), *variants[name]], text=True)
        pixels = np.fromfile(target, dtype='<f4').reshape(height, width, 4)[..., :3]
        assert np.isfinite(pixels).all(), f'{name}/{label}: non-finite HDR'
        return pixels, json.loads(output)

    report = {'checks': {}, 'timings': {}, 'scope': 'Isolated bloom GPU work, not game FPS'}
    # Odd and one-pixel targets exercise viewport rounding and clamping at every edge.
    for width, height in [(17, 11), (1, 1), (64, 32)]:
        field = np.ones((height, width, 4), dtype=np.float32)
        field[..., :3] = (4, 2, 1)
        reference = None
        for name in ['half', 'full']:
            pixels, _ = render(name, field, f'constant-{width}-{height}')
            assert np.max(np.abs(pixels - pixels[0, 0])) < 0.005, 'Stale pixels leaked at viewport edges'
            if reference is not None:
                assert np.max(np.abs(pixels - reference)) < 0.01, 'Resolution changed constant energy'
            reference = pixels
        black = field.copy()
        black[..., :3] = 0
        pixels, _ = render('half', black, f'black-{width}-{height}')
        assert np.max(np.abs(pixels)) == 0, 'Inactive buffer area leaked into black frame'
    report['checks']['constant_energy_odd_edges_black'] = True
    field = np.ones((64, 64, 4), dtype=np.float32)
    field[..., :3] = 0
    energies = []
    for x, y in [(30, 30), (31, 30), (30, 31), (31, 31)]:
        field[..., :3] = 0
        field[y, x, :3] = (8, 4, 2)
        pixels, _ = render('half', field, f'impulse-{x}-{y}')
        energies.append(float(pixels.sum()))
        bright = pixels[..., 0] > 0.001
        assert np.max(np.abs(pixels[..., 1][bright] / pixels[..., 0][bright] - 0.5)) < 0.005
        assert np.max(np.abs(pixels[..., 2][bright] / pixels[..., 0][bright] - 0.25)) < 0.005
    assert min(energies) > 0 and max(energies) / min(energies) < 1.01
    report['checks']['impulse_phase_energy'] = energies
    pixels, _ = render('off', field, 'disabled')
    assert np.max(np.abs(pixels)) == 0
    report['checks']['disabled_black'] = True
    # Dense HDR fixtures exercise both the bright and dark sides of the threshold.
    y, x = np.mgrid[:1080, :1920]
    field = np.ones((1080, 1920, 4), dtype=np.float32)
    field[..., :3] = 0.05
    field[(x // 48 + y // 48) % 3 == 0, :3] = (3, 1.8, 0.4)
    field[(x - 960) ** 2 + (y - 700) ** 2 < 36 ** 2, :3] = (35, 20, 8)
    field[(x % 59 == 0) & (y % 53 == 0), :3] = (2, 5, 10)
    for name in variants:
        if name == 'off':
            continue
        pixels, timing = render(name, field, 'hdr-1080p')
        report['timings'][name] = timing
        # Display preview is a simple diagnostic mapping, not a Minecraft screenshot.
        display = np.power(np.clip(pixels / (1 + pixels), 0, 1), 1 / 2.2)
        Image.fromarray(np.uint8(display * 255)).save(work / name / 'hdr-1080p.png')
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
