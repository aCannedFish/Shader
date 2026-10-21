#!/usr/bin/env python3
"""Check terrain-atmosphere data and optical bounds with the production GLSL."""
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


def terrain_input(width, height, *, slope=False, origin_x=-128, sky=15, block=0, valid=1, magic=2718):
    """Use the real reserved-row layout, including packed native light nibbles."""
    field = np.zeros((height, width, 4), dtype=np.float32)
    field[0, 0] = [2026, 0, 32, 0]
    field[0, 2, 0] = 4
    field[1, 0] = [origin_x, -128, 4, magic]
    field[1, 1] = [65, origin_x % 1024, (-128) % 1024, 1]
    for z in range(65):
        for x in range(65):
            index = 2 + z * 65 + x
            ground = 64 + ((origin_x + x * 4) * 0.25 + (z * 4 - 128) * 0.1 if slope else 0)
            field[1 + index // width, index % width] = [ground, 1, sky * 16 + block, valid]
    return field


def main():
    """Test actual kernels without Minecraft; native capture separately checks uploads."""
    work = ROOT / '.preview/atmosphere-verification'
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'atmosphere_probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    library = expand(ROOT / 'shaders/lib/sky_background.glsl', ROOT / 'shaders')
    library += expand(ROOT / 'shaders/lib/atmosphere_media.glsl', ROOT / 'shaders')
    header = '#version 150\n' + '\n'.join(f'#define {token} 0' for token in FORMAT_TOKENS)
    header += '\n'

    def run(name, body, *, field=None, settings=None, sun=-1.0, clock=0.0, rain=0.0, camera=65.0, dimension=0):
        """Override only fixtures; the material and integration functions stay unchanged."""
        if field is None:
            field = terrain_input(256, 128)
        height, width = field.shape[:2]
        text = library
        values = {'ENABLE_SHADOWS': '0', 'GI_BOUNCES': '0'}
        values.update(settings or {})
        for key, value in values.items():
            text = re.sub(r'(^#define ' + key + r'\s+)\S+', lambda match: match[1] + value,
                          text, flags=re.M)
        substitutions = {
            'uniform int companionReady;': 'const int companionReady = 1;',
            'uniform vec2 companionDimensions;': f'const vec2 companionDimensions = vec2({width}.0, {height}.0);',
            'uniform vec3 cameraPosition;': f'const vec3 cameraPosition = vec3(0.0, {camera}, 0.0);',
            'uniform vec3 sunPosition;': f'const vec3 sunPosition = vec3({np.sqrt(max(1-sun*sun, 0)) * 100.0}, {sun * 100.0}, 0.0);',
            'uniform float frameTimeCounter;': f'const float frameTimeCounter = {clock};',
            'uniform float rainStrength;': f'const float rainStrength = {rain};',
            'uniform float rainBiome;': 'const float rainBiome = 1.0;',
        }
        for old, new in substitutions.items():
            assert old in text, old
            text = text.replace(old, new)
        fragment = work / (name + '.frag')
        fragment.write_text(header + f'#define SIMPLE_DIMENSION ({dimension})\n'
                            + text.replace('texture2D(', 'texture(')
                            + '\nout vec4 result;\nvoid main() {\n' + body + '\n}\n')
        source = work / (name + '-input.f32')
        field.tofile(source)
        target = work / (name + '.f32')
        subprocess.run([str(binary), str(width), str(height), str(source), str(target),
                        '1.0', str(fragment)], check=True, stdout=subprocess.DEVNULL)
        output = np.fromfile(target, dtype=np.float32).reshape(height, width, 4)
        assert np.isfinite(output).all(), name + ': nonfinite output'
        return output

    sample_body = '''
    vec2 p = (gl_FragCoord.xy / vec2(viewWidth, viewHeight) - 0.5) * 192.0;
    float coverage;
    vec4 cell = sampleTerrainFog(p, terrainFogHeader(0.0), terrainFogHeader(1.0), coverage);
    result = cell;
'''
    sampled = run('cache-slope', sample_body, field=terrain_input(256, 128, slope=True, block=7))
    yy, xx = np.mgrid[:128, :256]
    px = ((xx + 0.5) / 256 - 0.5) * 192
    pz = ((yy + 0.5) / 128 - 0.5) * 192
    height_error = float(np.max(np.abs(sampled[..., 0] - (64 + px * 0.25 + pz * 0.1))))
    assert height_error < 0.07, 'Terrain bilinear reconstruction changed'
    assert np.max(np.abs(sampled[..., 2] - 1)) < 0.001
    assert np.max(np.abs(sampled[..., 3] - 7 / 15)) < 0.001, 'Packed light channels were interpolated before decoding'
    rebased = run('cache-rebased', sample_body, field=terrain_input(256, 128, slope=True, origin_x=-96, block=7))
    assert np.max(np.abs(sampled - rebased)) < 0.07, 'Grid rebasing moved terrain heights'
    density_body = '''
    vec4 cell = vec4(64.0, 1.0, 1.0, 0.0);
    vec3 nearPoint = vec3(0.0, 66.0 - cameraPosition.y, 0.0);
    vec3 highPoint = vec3(0.0, 80.0 - cameraPosition.y, 0.0);
    vec3 below = vec3(0.0, 60.0 - cameraPosition.y, 0.0);
    result = vec4(terrainMistDensity(nearPoint, cell, 1.0, vec2(0.0)),
                  terrainMistDensity(highPoint, cell, 1.0, vec2(0.0)),
                  terrainMistDensity(below, cell, 1.0, vec2(0.0)),
                  terrainMistDensity(nearPoint, vec4(64.0, 1.0, 0.0, 1.0), 1.0, vec2(0.0)));
'''
    density = run('density-height', density_body)
    assert density[..., 0].min() > density[..., 1].max() >= 0
    assert density[..., 2:].max() == 0, 'Mist entered ground or an enclosed column'
    # Rain mist must stay near the ground and cannot turn animated horizontal
    # noise into tall moving curtains. Exercise the real density at several heights.
    rain_profile_body = '''
    vec4 cell = vec4(64.0, 1.0, 1.0, 0.0);
    vec2 p = (gl_FragCoord.xy / vec2(viewWidth, viewHeight) - 0.5) * 192.0;
    result = vec4(
        terrainMistDensity(vec3(p.x, 66.0 - cameraPosition.y, p.y), cell, 1.0, p),
        terrainMistDensity(vec3(p.x, 70.0 - cameraPosition.y, p.y), cell, 1.0, p),
        terrainMistDensity(vec3(p.x, 76.0 - cameraPosition.y, p.y), cell, 1.0, p),
        terrainMistDensity(vec3(p.x, 88.0 - cameraPosition.y, p.y), cell, 1.0, p));
'''
    rain_profile = run('rain-low-layer', rain_profile_body, rain=1.0)
    assert rain_profile[..., 0].min() > 0
    assert np.max(rain_profile[..., 1] / rain_profile[..., 0]) < 0.4, 'Rain mist stayed dense above the ground layer'
    assert rain_profile[..., 2:].max() == 0, 'Rain mist rose into tall curtains'
    later_profile = run('rain-no-curtain-motion', rain_profile_body, rain=1.0, clock=90.0)
    assert np.max(np.abs(rain_profile - later_profile)) < 0.00001, 'Rain mist oscillated with the animation clock'
    volume_body = '''
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    result = integrateLocalAtmosphere(uv, 96.0);
'''
    volume = run('mist-bounds', volume_body, rain=1.0,
                 settings={'GROUND_FOG_STRENGTH': '1.0', 'GROUND_FOG_HEIGHT': '20.0'})
    assert volume[..., 3].max() <= 0.4005 and volume[..., 3].max() > 0.03
    assert volume.min() >= 0.0
    for name, kwargs in (
        ('mist-disabled', {'settings': {'GROUND_FOG_STRENGTH': '0.0'}}),
        ('missing-cache', {'field': terrain_input(256, 128, magic=0)}),
        ('unloaded-columns', {'field': terrain_input(256, 128, valid=0)}),
        ('indoor-columns', {'field': terrain_input(256, 128, sky=0, block=15)}),
    ):
        assert run(name, volume_body, **kwargs).max() == 0, name
    assert run('depth-clip', 'result = integrateLocalAtmosphere(vec2(0.5), 0.0);').max() == 0
    assert run('rain-mist-disabled', volume_body, rain=1.0,
               settings={'GROUND_FOG_STRENGTH': '0.0', 'RAIN_FOG_STRENGTH': '0.0'}).max() == 0
    # A post-blend fog correction must equal correcting the background first
    # and then placing the uncorrected rain over it. Opaque rain gets no fog tint.
    weather_blend = run('weather-fog-composition', '''
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    vec3 background = vec3(0.04, 0.08, 0.12);
    vec3 rain = vec3(0.001, 0.002, 0.004);
    float transmission = 0.35;
    float distance = far * 0.70;
    vec3 correctedBackground = correctSkyFog(background, uv, distance, 1.0);
    vec3 expected = correctedBackground * transmission + rain * (1.0 - transmission);
    vec3 observed = correctSkyFog(background * transmission + rain * (1.0 - transmission),
                                  uv, distance, transmission);
    result = vec4(length(observed - expected),
                  length(correctSkyFog(rain, uv, distance, 0.0) - rain),
                  length(correctedBackground - background), 1.0);
''', rain=1.0, sun=0.5)
    assert weather_blend[..., :2].max() < 0.001, 'Fog correction tinted the rain overlay'
    assert weather_blend[..., 2].mean() > 0.001, 'Weather composition fixture had no fog-colour correction'
    blend = run('media-merge', '''
    vec4 a = vec4(0.2, 0.1, 0.05, 0.25);
    vec4 b = vec4(0.1, 0.2, 0.1, 0.50);
    vec4 x = mergeAtmosphericMedia(a, b);
    vec4 y = mergeAtmosphericMedia(b, a);
    result = vec4(length(x - y), abs(x.a - 0.625), length(mergeAtmosphericMedia(a, vec4(0.0)) - a), 1.0);
''')
    assert blend[..., :3].max() < 0.001, 'Overlapping media lost optical-depth symmetry or energy bounds'
    aurora_body = '''
    vec2 p = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
    vec3 ray = normalize(vec3((p.x - 0.5) * 2.4, p.y * 1.2 + 0.02, -1.0));
    result = vec4(auroraRadiance(ray), 0.0);
'''
    aurora = run('aurora-night', aurora_body, field=terrain_input(512, 256))
    assert aurora[..., :3].mean() > 0.0001, 'Clear-night aurora was invisible'
    assert run('aurora-day', aurora_body, sun=0.5).max() == 0
    assert run('aurora-off', aurora_body, settings={'AURORA_STRENGTH': '0.0'}).max() == 0
    assert run('aurora-below', 'result = vec4(auroraRadiance(vec3(0.0, -1.0, 0.0)), 0.0);').max() == 0
    rainy = run('aurora-rain', aurora_body, field=terrain_input(512, 256), rain=1.0)
    rain_ratio = float(rainy[..., :3].sum() / aurora[..., :3].sum())
    assert abs(rain_ratio - 0.05) < 0.001
    moving = run('aurora-motion', aurora_body, field=terrain_input(512, 256), clock=90.0)
    assert np.abs(moving - aurora).mean() > 0.0001, 'Aurora did not move'
    frozen = run('aurora-frozen', aurora_body, field=terrain_input(512, 256), clock=90.0,
                 settings={'AURORA_SPEED': '0'})
    assert np.max(np.abs(frozen - aurora)) == 0, 'Freeze control changed the emission geometry'
    wrapped = run('aurora-hour-wrap', aurora_body, field=terrain_input(512, 256), clock=3600.0)
    assert np.max(np.abs(wrapped - aurora)) < 0.001, 'Loader clock wrap caused an aurora jump'
    twilight_body = 'result = vec4(twilightIrradiance(vec3(1.0, 0.0, 0.0)), atmosphereTwilight());'
    twilight = run('twilight-horizon', twilight_body, sun=0.0)
    noon = run('twilight-noon', twilight_body, sun=0.8)
    assert twilight[..., 3].mean() > noon[..., 3].mean() + 0.5
    for dimension in (-1, 1):
        suppressed = run(f'other-world-solar-{dimension}', '''
    result = vec4(auroraRadiance(vec3(0.0, 0.5, -0.866)), atmosphereTwilight());
''', dimension=dimension)
        assert suppressed.max() == 0, 'Overworld effects leaked into another dimension'
    report = {'terrain_height_max_error': height_error,
              'mist_max_opacity': float(volume[..., 3].max()),
              'rain_density_at_six_over_two_blocks': float(np.max(rain_profile[..., 1] / rain_profile[..., 0])),
              'rain_ground_layer_and_static_density': True,
              'weather_fog_composition': True,
              'night_aurora_mean': float(aurora[..., :3].mean()),
              'aurora_rain_ratio': rain_ratio,
              'terrain_and_visibility_checks': True, 'media_optical_checks': True,
              'aurora_visibility_motion_and_wrap': True, 'twilight_and_dimensions': True,
              'scope': 'Production GLSL on macOS OpenGL; mock terrain atlas, real RGBA16F output'}
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
