#!/usr/bin/env python3
"""Check zero-contribution fog/shadow work against saved production shaders."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VENV = ROOT / '.preview/venv/bin/python'
if VENV.exists() and Path(sys.prefix).resolve() != VENV.parent.parent.resolve():
    os.execv(str(VENV), [str(VENV), str(Path(__file__).resolve()), *sys.argv[1:]])

import numpy as np
from check_glsl import FORMAT_TOKENS
from preview.source import expand


def main():
    """Compare final terrain lighting, debug shadows and fog without lowering quality."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-shaders', type=Path, required=True)
    args = parser.parse_args()
    work = ROOT / '.preview/fog-optimization'
    work.mkdir(exist_ok=True)
    binary = work / 'probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    width, height = 1280, 720
    y, x = np.mgrid[:height, :width]
    data = np.ones((height, width, 4), np.float32)
    data[..., :3] = np.stack((0.1 + x / width, 0.2 + y / height,
                             0.3 + (x + y) / (width + height)), axis=-1)
    source = work / 'input.f32'
    data.tofile(source)
    header = '#version 150\n' + ''.join(f'#define {name} 0\n' for name in FORMAT_TOKENS)
    cases = {'near': ('far * 0.25', '1.0'),
             'mixed': ('far * uv.x', '1.0'),
             'far': ('far * 0.90', '1.0'),
             'weather': ('far * 0.90', 'step(0.75, uv.x)'),
             'shadow_indoor': ('', ''), 'shadow_mixed': ('', ''),
             'shadow_quartz': ('', ''), 'shadow_debug': ('', '')}
    report = {'size': [width, height], 'cases': {},
              'scope': 'Production terrain lighting and fog; synchronized wall time includes driver overhead, not game FPS'}
    for case, (distance, transmission) in cases.items():
        paths = []
        outputs = []
        for name, shaders in (('before', args.baseline_shaders.resolve()), ('after', ROOT / 'shaders')):
            if case.startswith('shadow_'):
                library = expand(shaders / 'lib/shadow.glsl', shaders)
                library += expand(shaders / 'lib/material_lighting.glsl', shaders)
                call = ('getSurfaceShadowFactor(clip, normal, length(position), lm.y)'
                        if 'vec3 getSurfaceShadowFactor' in library else
                        'getShadowFactor(clip, normal, length(position))')
                sky = '0.03125' if case == 'shadow_indoor' else 'mix(0.03125, 0.96875, uv.x)'
                kind = '6.0' if case == 'shadow_quartz' else '0.0'
                body = '''
    vec3 position = screenToView(uv, 0.8);
    vec3 normal = normalize(vec3(0.15, 1.0, 0.2));
    vec4 clip = vec4(uv * 1.4 - 0.7, 0.0, 1.0);
    vec2 lm = vec2(0.5, SKY);
    vec3 shadow = SHADOW;
    vec3 color = computeMaterialLighting(vec3(0.4), normal, lm, shadow, 0.8, position, KIND);
    result = vec4(OUTPUT, 1.0);
'''.replace('SKY', sky).replace('SHADOW', call).replace('KIND', kind)
                body = body.replace('OUTPUT', 'shadow' if case == 'shadow_debug' else 'color')
                if case == 'shadow_debug':
                    library = library.replace('#define DEBUG_VIEW 0', '#define DEBUG_VIEW 3')
            else:
                library = expand(shaders / 'lib/sky_background.glsl', shaders)
                body = '''
    vec3 color = texture(source, uv).rgb;
    result = vec4(correctSkyFog(color, uv, DISTANCE, TRANSMISSION), 1.0);
'''.replace('DISTANCE', distance).replace('TRANSMISSION', transmission)
            library = library.replace('texture2D(', 'texture(')
            fragment = work / f'{name}-{case}.frag'
            fragment.write_text(header + library + '''
uniform sampler2D source;
out vec4 result;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
''' + body + '}\n')
            paths.append(fragment)
            target = work / f'{name}-{case}.f32'
            subprocess.run([str(binary), str(width), str(height), str(source), str(target),
                            '1.0', str(fragment)], check=True, stdout=subprocess.DEVNULL)
            pixels = np.fromfile(target, np.float32).reshape(data.shape)
            assert np.isfinite(pixels).all()
            outputs.append(pixels)
        error = float(np.abs(outputs[0] - outputs[1]).max())
        assert error == 0.0, case + ': surface or fog radiance changed'
        environment = os.environ.copy()
        environment['SIMPLESHADER_PROBE_SPLIT'] = '1'
        environment['SIMPLESHADER_PROBE_WALL_TIME'] = '1'
        runs = []
        for _ in range(3):
            result = subprocess.check_output([str(binary), str(width), str(height), str(source),
                str(work / 'paired.f32'), '1.0', str(paths[0]), '1.0', str(paths[1])],
                env=environment, text=True)
            runs.append(json.loads(result))
        before = statistics.median(row['first_ms'] for row in runs)
        after = statistics.median(row['second_ms'] for row in runs)
        report['cases'][case] = {'max_error': error, 'before_ms': before, 'after_ms': after,
                                 'paired_runs': runs}
        print(f'{case}: {before:.4f} -> {after:.4f} ms, error {error}', flush=True)
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
