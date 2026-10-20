#!/usr/bin/env python3
"""Verify mineral-mask decoding, atlas precision and zero-emission fallbacks."""
import json
import os
from pathlib import Path
import re
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
    """Use the production GLSL with exact half-float atlas bytes and split UVs."""
    work = ROOT / '.preview/ore-verification'
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'ore_probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    width, height = 1152, 64
    field = np.zeros((height, width, 4), dtype=np.float32)
    field[0, 0, 0] = 2026
    field[0, 2, 0] = 4
    field[8, 0] = [3142, 64, 18, 38]
    yy, xx = np.mgrid[:64, :64]
    masks = []
    origin = np.array([0.673421, 0.194283], dtype=np.float32)
    high = np.floor(origin * 1024) / 1024
    span = 1 / 128
    for ore in range(18):
        index = 2 + ore * 2
        field[8, index] = [*high, span, span]
        field[8, index + 1, :2] = origin - high
        # Distinct asymmetric masks exercise every byte, channel and row wrap.
        mask = ((xx // 4 + yy // 4 * 3 + ore) % 5 == 0)
        masks.append(mask)
        bits = np.packbits(mask.reshape(-1), bitorder='little').astype(np.float32)
        for offset in range(128):
            index = 38 + ore * 128 + offset
            field[8 + index // width, index % width] = bits[offset * 4:offset * 4 + 4]
    field = field.astype(np.float16).astype(np.float32)
    source = work / 'atlas.f32'
    field.tofile(source)
    library = expand(ROOT / 'shaders/lib/ore_emission.glsl', ROOT / 'shaders')
    header = '#version 150\n' + '\n'.join(f'#define {token} 0' for token in FORMAT_TOKENS)
    body = '''
out vec4 result;
void main() {
    float ore = floor(gl_FragCoord.x / 64.0);
    vec2 local = vec2(mod(gl_FragCoord.x, 64.0), gl_FragCoord.y) / 64.0;
    vec2 uv = vec2(0.673421, 0.194283) + local / 128.0;
    result = vec4(oreEmission(400.0 + ore, uv, vec3(0.55, 0.8, 0.7)), 0.0);
}
'''

    def run(name, *, option=None, ready=1, edit=None):
        """Only fixture uniforms change; every mask read uses the shipped library."""
        text = library.replace('uniform int companionReady;', f'const int companionReady = {ready};')
        text = text.replace('uniform vec2 companionDimensions;',
                            f'const vec2 companionDimensions = vec2({width}.0, {height}.0);')
        if option is not None:
            text = re.sub(r'(^#define ORE_GLOW_STRENGTH\s+)\S+',
                          lambda match: match[1] + option, text, flags=re.M)
        fragment = work / (name + '.frag')
        fragment.write_text(header + text.replace('texture2D(', 'texture(') + (edit or body))
        target = work / (name + '.f32')
        subprocess.run([str(binary), str(width), str(height), str(source), str(target),
                        '1.0', str(fragment)], check=True, stdout=subprocess.DEVNULL)
        result = np.fromfile(target, dtype=np.float32).reshape(height, width, 4)
        assert np.isfinite(result).all()
        return result

    actual = run('default')
    # Coal uses the same packed-mask path but intentionally emits no light.
    # The remaining ore kinds retain their authored weak/strong mineral glow.
    expected = np.concatenate([np.zeros_like(mask) if ore < 2 else mask
                               for ore, mask in enumerate(masks)], axis=1)
    emitted = actual[..., :3].max(axis=2) > 0
    assert np.array_equal(emitted, expected), 'Rock emitted or mineral pixels were lost'
    assert run('off', option='0.0').max() == 0
    assert run('no-companion', ready=0).max() == 0
    assert run('unlisted-block', edit=body.replace('400.0 + ore', '1.0')).max() == 0
    stronger = run('stronger', option='1.6')
    assert np.max(np.abs(stronger - actual * 2)) < 0.002, 'Intensity control is not linear'
    field[8, 0, 0] = 0
    field.tofile(source)
    assert run('old-companion').max() == 0
    report = {'ores_checked': 18, 'emissive_ore_types': 16, 'coal_emission_disabled': True,
              'pixels_checked': int(expected.size),
              'rock_pixels_emitting': int(np.count_nonzero(emitted & ~expected)),
              'mask_bits_and_split_uv_exact': True, 'strength_and_fallbacks': True,
              'scope': 'Production GLSL on macOS OpenGL; RGBA16F-quantized mock atlas. Native capture checks resource-derived masks.'}
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
