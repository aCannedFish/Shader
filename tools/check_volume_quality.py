#!/usr/bin/env python3
"""Compare actual half/quarter cloud-integration stages on one OpenGL context.

The HDR fixture uses dense constant noise and a sky-depth input. It measures the
cloud stage, not reconstruction, atmosphere caches, geometry, Mod work or game FPS.
Both variants use identical camera/light inputs and the same quality/sample counts.
"""
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
venv = ROOT / '.preview/venv/bin/python'
if venv.exists() and Path(sys.prefix).resolve() != venv.parent.parent.resolve():
    os.execv(str(venv), [str(venv), str(Path(__file__).resolve()), *sys.argv[1:]])

import numpy as np
from check_glsl import FORMAT_TOKENS
from preview.source import expand


def main():
    work = ROOT / '.preview/volume-quality-verification'
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'volume_probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    width, height = 1280, 720
    original = work / 'input.f32'
    np.ones((height, width, 4), dtype=np.float32).tofile(original)
    source = expand(ROOT / 'shaders/composite.fsh', ROOT / 'shaders')
    source = source.replace('#version 120', '#version 150\n' +
        '\n'.join(f'#define {token} 0' for token in FORMAT_TOKENS))
    source = source.replace('texture2D(', 'texture(').replace('varying ', 'in ')
    source = source.replace('gl_FragData[0]', 'result').replace('void main()', 'out vec4 result;\nvoid main()')
    arguments = []
    coverage = {}
    for name, option, scale in [('half', 1, 0.5), ('quarter', 0, 0.25)]:
        shader = work / (name + '.frag')
        shader.write_text(re.sub(r'(#define VOLUMETRIC_RESOLUTION) \d+', rf'\g<1> {option}', source))
        arguments.extend([str(scale), str(shader)])
        target = work / (name + '.f32')
        subprocess.run([str(binary), str(width), str(height), str(original), str(target),
                        str(scale), str(shader)], check=True, stdout=subprocess.DEVNULL)
        pixels = np.fromfile(target, dtype=np.float32).reshape(height, width, 4)
        active = pixels[:int(height * scale), :int(width * scale)]
        assert np.isfinite(active).all()
        assert active[..., 3].max() > 0.5, 'The cloud integration workload is empty'
        assert active[..., 3].min() >= 0 and active[..., 3].max() <= 1.001
        coverage[name] = float(np.mean(active[..., 3] > 0.5))
    environment = os.environ.copy()
    environment['SIMPLESHADER_PROBE_SPLIT'] = '1'
    runs = []
    for _ in range(3):
        output = subprocess.check_output([str(binary), str(width), str(height), str(original),
            str(work / 'paired.f32'), *arguments], env=environment, text=True)
        runs.append(json.loads(output))
    report = {'size': [width, height], 'paired_runs': runs,
              'median_half_ms': statistics.median(row['first_ms'] for row in runs),
              'median_quarter_ms': statistics.median(row['second_ms'] for row in runs),
              'dense_cloud_coverage': coverage,
              'scope': 'Cloud integration only, fixed synthetic dense weather; not game FPS'}
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
