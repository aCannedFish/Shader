#!/usr/bin/env python3
"""Run the real packed sky lookup on the GPU and test periodic azimuth seams.

The fixture fills unused attachment areas with a bright sentinel. Matching
azimuths at 0 and 1 must agree in both sky and cloud strips, including poles,
odd attachment dimensions and a one-column LUT. No Minecraft capture is needed.
"""
import json
import os
from pathlib import Path
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
    work = ROOT / '.preview/sky-cache-verification'
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'sky_probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    library = expand(ROOT / 'shaders/lib/sky.glsl', ROOT / 'shaders').replace('texture2D(', 'texture(')
    header = '#version 150\n' + '\n'.join(f'#define {token} 0' for token in FORMAT_TOKENS)
    header += '\n' + library + '\nout vec4 result;\n'
    results = []
    for width, height in [(128, 64), (31, 21), (8, 16)]:
        sx, sy = max(width // 8, 1), max(height // 8, 1)
        field = np.full((height, width, 4), 100, dtype=np.float32)
        y, x = np.mgrid[:sy, :sx]
        angle = (x + 0.5) / sx * 2 * np.pi
        for strip in range(2):
            field[strip * sy:(strip + 1) * sy, :sx, 0] = 0.4 + 0.2 * np.cos(angle)
            field[strip * sy:(strip + 1) * sy, :sx, 1] = 0.4 + 0.2 * np.sin(angle)
            field[strip * sy:(strip + 1) * sy, :sx, 2] = 0.1 + strip * 0.4 + y * 0.03
            field[strip * sy:(strip + 1) * sy, :sx, 3] = 0.25 + strip * 0.5
        original = work / 'input.f32'
        field.tofile(original)
        for strip in range(2):
            fragment = work / f'strip-{strip}.frag'
            fragment.write_text(header + '''void main() {
    float azimuth = gl_FragCoord.x < viewWidth * 0.5 ? 0.0 : 1.0;
    float latitude = (gl_FragCoord.y - 0.5) / max(viewHeight - 1.0, 1.0);
    result = sampleSkyStrip(vec2(azimuth, latitude), ''' + f'{strip}.0' + ''');
}
''')
            target = work / 'output.f32'
            subprocess.run([str(binary), str(width), str(height), str(original), str(target),
                            '1.0', str(fragment)], check=True, stdout=subprocess.DEVNULL)
            image = np.fromfile(target, dtype=np.float32).reshape(height, width, 4)
            assert np.isfinite(image).all()
            error = float(np.max(np.abs(image[:, 0] - image[:, -1])))
            assert error == 0, f'Azimuth seam is discontinuous: {width}x{height}/{strip}'
            assert image.max() < 1.0, 'Neighbouring packed region leaked into the lookup'
            expected = 0.1 + strip * 0.4 + np.linspace(0, sy - 1, height) * 0.03
            pole_error = float(np.max(np.abs(image[:, 0, 2] - expected)))
            assert pole_error < 0.001, 'Latitude mapping or strip offset changed'
            results.append({'size': [width, height], 'strip': strip,
                            'seam_error': error, 'latitude_error': pole_error})
    report = {'checks': results, 'scope': 'Actual GLSL lookup on macOS OpenGL'}
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
