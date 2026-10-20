#!/usr/bin/env python3
"""Exercise production glossy filtering, environment energy and corner visibility on GPU."""
import json
import os
from pathlib import Path
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
    """Use shared GLSL and analytic geometry; do not infer correctness from brightness alone."""
    work = ROOT / '.preview/reflection-verification'
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    header = '#version 150\n' + ''.join(f'#define {name} 0\n' for name in FORMAT_TOKENS)
    shaders = ROOT / 'shaders'

    def run(name, pixels, library, body, defines='', mips=False):
        height, width, _ = pixels.shape
        source, target = work / (name + '-input.f32'), work / (name + '.f32')
        pixels.astype(np.float32).tofile(source)
        fragment = work / (name + '.frag')
        fragment.write_text(header + defines + library.replace('texture2D(', 'texture(')
                            + '\nout vec4 result;\nvoid main(){\n' + body + '\n}\n')
        environment = os.environ.copy()
        if mips:
            environment['SIMPLESHADER_PROBE_INPUT_MIPS'] = '1'
        subprocess.run([str(binary), str(width), str(height), str(source), str(target),
                        '1.0', str(fragment)], check=True, env=environment, stdout=subprocess.DEVNULL)
        image = np.fromfile(target, np.float32).reshape(height, width, 4)
        assert np.isfinite(image).all(), name + ': nonfinite output'
        return image

    materials = expand(shaders / 'lib/materials.glsl', shaders)
    energy = run('environment', np.zeros((128, 256, 4)), materials, '''
    float cosine = gl_FragCoord.x / 256.0;
    SurfaceMaterial obsidian = surfaceMaterial(9.0, 0.1);
    SurfaceMaterial metal = surfaceMaterial(1.0, 0.5);
    vec3 weight = materialEnvironmentWeight(obsidian, cosine);
    vec3 old = mix(materialFresnel(vec3(0.04), cosine), vec3(0.04), 0.27 * 0.27);
    result = vec4(weight.r, old.r, obsidian.roughness, materialEnvironmentWeight(metal, cosine).r);
''')
    assert (energy[..., :2] >= 0).all() and (energy[..., :2] <= 1).all()
    assert energy[..., 2].min() > 0.82, 'Obsidian is not sufficiently rough for a diffuse-dominant appearance'
    assert energy[:, :100, 0].mean() < energy[:, :100, 1].mean() * 0.8
    assert energy[..., 3].mean() > energy[..., 0].mean(), 'Metal reflection was globally disabled'

    checker = np.ones((128, 256, 4), np.float32)
    checker[..., :3] = ((np.indices((128, 256)).sum(axis=0) % 2)[..., None])
    library = ('uniform sampler2D colortex0; uniform sampler2D colortex1; uniform sampler2D colortex5;\n'
               'vec3 sceneSkyBackground(vec2 uv){return vec3(0.25,0.5,1.0);}\n'
               + expand(shaders / 'lib/material_reflection.glsl', shaders))
    body = '''
    vec2 uv = gl_FragCoord.xy / vec2(256,128);
    result = vec4(filterMaterialHit(colortex0,colortex5,uv,0.01,1.0,0.55),1.0);
'''
    filtered = run('foliage-footprint', checker, library, body,
                   '#define MATERIAL_REFLECTION_MIPS\n', True)
    interior = filtered[12:-12, 12:-12, :3]
    assert np.abs(interior - 0.5).max() < 0.003, 'Fine geometry aliases instead of being integrated'
    sky = run('sky-coverage', np.zeros_like(checker), library, body,
              '#define MATERIAL_REFLECTION_MIPS\n', True)
    assert np.abs(sky[..., :3] - (0.25, 0.5, 1.0)).max() < 0.003, 'Sky clear colour dirties foliage mips'

    resolution = 32
    inner, width, height = resolution - 2, resolution * 24, 16 + 3 * resolution
    atlas = np.ones((height, width, 4), np.float32)
    occluded = np.ones_like(atlas)
    eye = np.array([0.5, 0.72, 0.5])
    for face in range(6):
        for y in range(inner):
            for x in range(inner):
                a, b = 2 * (x + 0.5) / inner - 1, 2 * (y + 0.5) / inner - 1
                rays = [[1,-b,-a],[-1,-b,a],[a,1,b],[a,-1,-b],[a,-b,1],[-a,-b,-1]]
                direction = np.array(rays[face], dtype=float)
                direction /= np.linalg.norm(direction)
                distance = 16.0
                for axis in range(3):
                    if direction[axis] < 0:
                        candidate = -eye[axis] / direction[axis]
                        if candidate < distance and np.all(eye + candidate * direction >= -1e-5):
                            distance = candidate
                atlas[17 + y, face * resolution + 1 + x, 0] = np.float16(distance / 16.0)
                blocked = distance
                if direction[0] > 0:
                    candidate = (1.0 - eye[0]) / direction[0]
                    if candidate < blocked and np.all(eye + candidate * direction >= -1e-5):
                        blocked = candidate
                occluded[17 + y, face * resolution + 1 + x, 0] = np.float16(blocked / 16.0)
    visibility = run('corner', atlas, expand(shaders / 'lib/companion_lighting.glsl', shaders), '''
    vec2 p=gl_FragCoord.xy/vec2(768,112)*2.0;
    result=vec4(companionShadow(0,vec3(p.x-.5,-.72,p.y-.5),16.0,vec3(0,1,0),vec3(1)),1);
''', '#define LOCAL_LIGHT_COUNT 8\n#define LOCAL_SHADOW_RESOLUTION 32\n')
    deficit = float((1 - visibility[..., 0]).mean())
    assert deficit < 0.001, 'Directly lit inner corner still has excessive self-shadowing'
    blocker = run('corner-blocker', occluded, expand(shaders / 'lib/companion_lighting.glsl', shaders), '''
    vec2 p=gl_FragCoord.xy/vec2(768,112)*2.0;
    result=vec4(companionShadow(0,vec3(p.x-.5,-.72,p.y-.5),16.0,vec3(0,1,0),vec3(1)),1);
''', '#define LOCAL_LIGHT_COUNT 8\n#define LOCAL_SHADOW_RESOLUTION 32\n')
    blocked_mean = float(blocker[16:-16, int(width * 0.72):, 0].mean())
    assert blocked_mean < 0.3, 'Corner bias removed real opaque-wall shadows'
    result = {'checker_max_error': float(np.abs(interior - 0.5).max()),
              'sky_coverage_max_error': float(np.abs(sky[..., :3] - (0.25,0.5,1.0)).max()),
              'corner_mean_visibility': float(visibility[..., 0].mean()),
              'corner_false_dark_pixels': int(np.count_nonzero(visibility[..., 0] < 0.999)),
              'opaque_wall_visibility': blocked_mean,
              'obsidian_roughness_min': float(energy[..., 2].min()),
              'scope': 'Production GLSL, analytic corner at 32-pixel cube faces and RGBA16F depth quantization'}
    (work / 'verification.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
