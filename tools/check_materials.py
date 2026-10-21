#!/usr/bin/env python3
"""Check material optics, full-sphere normals and dimension isolation on macOS GPU."""
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
    """Exercise actual production functions rather than a second CPU implementation."""
    work = ROOT / '.preview/material-verification'
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'material_probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    width, height = 256, 128
    source = work / 'input.f32'
    np.zeros((height, width, 4), dtype=np.float32).tofile(source)
    header = '#version 150\n' + '\n'.join(f'#define {token} 0' for token in FORMAT_TOKENS) + '\n'
    shader_root = ROOT / 'shaders'
    materials = expand(shader_root / 'lib/materials.glsl', shader_root)

    def run(name, library, body, dimension=0):
        """Compile the shared fixture and return linear HDR output for assertions."""
        fragment = work / (name + '.frag')
        text = header + f'#define SIMPLE_DIMENSION {dimension}\n' + library
        text = text.replace('texture2D(', 'texture(')
        fragment.write_text(text + '\nout vec4 result;\nvoid main() {\n' + body + '\n}\n')
        target = work / (name + '.f32')
        subprocess.run([str(binary), str(width), str(height), str(source), str(target),
                        '1.0', str(fragment)], check=True, stdout=subprocess.DEVNULL)
        output = np.fromfile(target, dtype=np.float32).reshape(height, width, 4)
        assert np.isfinite(output).all(), name + ': nonfinite radiance'
        return output

    normals = run('normal-sphere', materials, '''
    float azimuth = gl_FragCoord.x / 256.0 * TAU;
    float y = gl_FragCoord.y / 128.0 * 2.0 - 1.0;
    float horizontal = sqrt(1.0 - y * y);
    vec3 n = vec3(cos(azimuth) * horizontal, y, sin(azimuth) * horizontal);
    vec2 encoded = floor(encodeNormal(n) * 255.0 + 0.5) / 255.0;
    vec3 restored = decodeNormal(encoded);
    float angle = acos(clamp(dot(n, restored), -1.0, 1.0)) * 180.0 / PI;
    result = vec4(angle, abs(n.z) > 0.02 && n.z * restored.z < 0.0 ? 1.0 : 0.0, 0.0, 1.0);
''')
    assert normals[..., 0].max() < 1.0, 'RGBA8 full-sphere normal error exceeds one degree'
    assert normals[..., 1].max() == 0.0, 'Normal hemisphere was lost'
    packing = run('material-byte', materials, '''
    float kind = floor((gl_FragCoord.x - 0.5) / 16.0);
    float detail = (gl_FragCoord.y - 0.5) / 127.0;
    float encoded = floor(packMaterial(kind, detail) * 255.0 + 0.5) / 255.0;
    vec2 value = unpackMaterial(encoded);
    result = vec4(abs(value.x - kind), abs(value.y - detail), 0.0, 1.0);
''')
    assert packing[..., 0].max() == 0.0, 'Material class changed in RGBA8 storage'
    assert packing[..., 1].max() <= 1.0 / 30.0 + 0.001, 'Texture-detail quantization exceeds budget'
    brdf = run('brdf-reciprocity', materials, '''
    SurfaceMaterial m = surfaceMaterial(floor(gl_FragCoord.x / 18.0), 0.5);
    vec3 n = vec3(0.0, 1.0, 0.0);
    float t = gl_FragCoord.y / 128.0;
    vec3 v = normalize(vec3(0.2, 0.02 + t, 0.5));
    vec3 l = normalize(vec3(-0.4, 1.02 - t, -0.3));
    vec3 a = materialLightSpecular(m, n, v, l, vec3(1.0)) / dot(n, l);
    vec3 b = materialLightSpecular(m, n, l, v, vec3(1.0)) / dot(n, v);
    float error = length(a - b) / max(length(a), 0.00001);
    vec3 back = materialLightSpecular(m, n, v, -n, vec3(1.0));
    vec3 grazing = materialFresnel(m.f0, 0.0);
    result = vec4(error, length(back), length(grazing - 1.0), min(min(a.r, a.g), a.b));
''')
    assert brdf[..., :3].max() < 0.002, 'Reciprocity, backface rejection or grazing Fresnel failed'
    assert brdf[..., 3].min() >= 0.0, 'Negative specular energy'
    # Rough water and puddle films must not retain a perfect-mirror grazing
    # lobe. Keep the near-normal water response while bounding the edge energy.
    films = run('water-film-environment', materials, '''
    float cosine = gl_FragCoord.x / 256.0;
    SurfaceMaterial water;
    water.f0 = vec3(0.079176);
    water.roughness = 0.25;
    water.metallic = 0.0;
    SurfaceMaterial puddle = water;
    puddle.f0 = vec3(0.025);
    puddle.roughness = 0.20;
    result = vec4(materialEnvironmentWeight(water, cosine).r,
                  materialFresnel(water.f0, cosine).r,
                  materialEnvironmentWeight(puddle, cosine).r,
                  materialFresnel(puddle.f0, cosine).r);
''')
    assert films[..., (0, 2)].min() >= 0.0 and films[..., (0, 2)].max() <= 1.0
    assert films[:, :12, 0].mean() < films[:, :12, 1].mean() * 0.75
    assert films[:, :12, 2].mean() < films[:, :12, 3].mean() * 0.75
    assert films[:, -12:, 0].mean() > films[:, -12:, 1].mean() * 0.75
    hemisphere = run('offscreen-hemisphere', expand(shader_root / 'lib/material_environment.glsl', shader_root), '''
    result = vec4(reflectionSkyVisibility(vec3(0.0, -0.2, 0.98), 0.25),
                  reflectionSkyVisibility(vec3(0.0, 0.2, 0.98), 0.25),
                  reflectionSkyVisibility(vec3(0.0, 0.0, 1.0), 0.25), 1.0);
''')
    assert hemisphere[..., 0].max() == 0.0 and hemisphere[..., 1].min() == 1.0
    assert np.max(np.abs(hemisphere[..., 2] - 0.5)) < 0.001
    transparent = expand(shader_root / 'lib/transparency.glsl', shader_root)
    layer = run('transparent-layer', transparent, '''
    vec3 background = vec3(0.10, 0.20, 0.40);
    vec4 first = vec4(2.0, 0.10, 0.20, 0.25);
    vec4 second = vec4(0.03, 0.08, 0.10, 0.30);
    vec4 combined = vec4(second.rgb + first.rgb * (1.0 - second.a),
                          second.a + first.a * (1.0 - second.a));
    vec3 sequential = applyTransparentLayer(applyTransparentLayer(background, first), second);
    vec3 composed = applyTransparentLayer(background, combined);
    result = vec4(length(sequential - composed),
                  transparentLayerInFront(5.0, 8.0, first.a) ? 0.0 : 1.0,
                  transparentLayerInFront(12.0, 8.0, first.a) ? 1.0 : 0.0,
                  applyTransparentLayer(background, first).r);
''')
    assert layer[..., :3].max() < 0.001, 'Glass layer composition or front/back order failed'
    assert layer[..., 3].min() > 1.0, 'Transparent HDR radiance was clamped'
    surface_input = np.empty((height, width, 4), dtype=np.float32)
    surface_input[:] = [0.5, 0.5, 12.0, 1.0]
    surface_input.tofile(source)
    surface = run('water-surface-metadata', 'uniform sampler2D source;\n'
                  + expand(shader_root / 'lib/water.glsl', shader_root), '''
    vec2 uv = gl_FragCoord.xy / vec2(256, 128);
    result = readWaterSurface(source, source, uv);
''')
    assert np.max(np.abs(surface - (0.5, 0.5, 0.5, 12.0))) < 0.001
    np.zeros((height, width, 4), dtype=np.float32).tofile(source)
    dimension_library = expand(shader_root / 'lib/clouds.glsl', shader_root)
    dimension_library += expand(shader_root / 'lib/fog.glsl', shader_root)
    dimensions = {}
    for dimension, name in ((-1, 'nether'), (1, 'end')):
        image = run(name, dimension_library, '''
    float distance = gl_FragCoord.x / 256.0 * far * 1.2;
    vec3 ray = normalize(vec3(gl_FragCoord.x / 128.0 - 1.0, 0.3, 1.0));
    float entry;
    float exit;
    float cloud = cloudRayInterval(cameraPosition, ray, far, entry, exit) ? 1.0 : 0.0;
    float solar = length(getSunLightColor() + getMoonLightColor() + skyCelestialRadiance(ray));
    result = vec4(getFogFactor(distance), luma(dimensionAmbient(ray)),
                  luma(integrateAtmosphere(ray)), solar + cloud + getNightFactor());
''', dimension)
        assert image[..., 3].max() == 0.0, name + ': overworld sky or night exposure leaked'
        assert np.diff(image[0, :, 0]).min() >= 0.0, name + ': nonmonotonic distance fog'
        assert image[..., 0].min() >= 0.0 and image[..., 0].max() == 1.0
        assert image[..., 1:3].min() > 0.0, name + ': environment visibility was lost'
        dimensions[name] = {'solar_cloud_night_leak': float(image[..., 3].max()),
                            'ambient_min': float(image[..., 1].min()),
                            'background_min': float(image[..., 2].min())}
    report = {'normal_max_angle_degrees': float(normals[..., 0].max()),
              'class_error': float(packing[..., 0].max()),
              'brdf_max_relative_error': float(brdf[..., 0].max()),
              'water_grazing_energy': float(films[:, :12, 0].mean()),
              'puddle_grazing_energy': float(films[:, :12, 2].mean()),
              'transparent_layer_and_water_metadata': True,
              'dimensions': dimensions,
              'scope': 'Production GLSL on macOS OpenGL, RGBA16F readback'}
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
