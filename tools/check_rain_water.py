#!/usr/bin/env python3
"""Check rain reconstruction, splash colours and water normals with production GLSL."""
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
    """Validate layer algebra and filtering independently of a particular camera."""
    work = ROOT / '.preview/rain-water-fixes/gpu'
    work.mkdir(parents=True, exist_ok=True)
    binary = work / 'probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    header = '#version 150\n' + ''.join(f'#define {name} 0\n' for name in FORMAT_TOKENS)
    shaders = ROOT / 'shaders'

    def run(name, library, body, width=256, height=64):
        """Execute the actual helper functions in a floating-point framebuffer."""
        source, target = work / (name + '-input.f32'), work / (name + '.f32')
        np.zeros((height, width, 4), np.float32).tofile(source)
        library = library.replace('texture2D(', 'texture(')
        library = library.replace('uniform float rainStrength;', 'const float rainStrength = 1.0;')
        library = library.replace('uniform float rainBiome;', 'const float rainBiome = 1.0;')
        fragment = work / (name + '.frag')
        fragment.write_text(header + library + '\nout vec4 result;\nvoid main(){\n'
                            + body + '\n}\n')
        subprocess.run([str(binary), str(width), str(height), str(source), str(target),
                        '1.0', str(fragment)], check=True, stdout=subprocess.DEVNULL)
        pixels = np.fromfile(target, np.float32).reshape(height, width, 4)
        assert np.isfinite(pixels).all(), name + ': nonfinite output'
        return pixels

    weather = expand(shaders / 'lib/weather.glsl', shaders)
    overlay = run('rain-overlay', weather, '''
    float a = gl_FragCoord.x / 256.0 * 0.45;
    float b = gl_FragCoord.y / 64.0 * 0.45;
    vec3 background = vec3(0.05, 0.15, 0.30);
    vec3 rain = toLinearSpace(rainDropAlbedo()) * 0.7;
    vec3 expected = mix(mix(background, rain, a), rain, b);
    vec4 parameters = vec4(0.6, 0.12, 0.0, 1.0)
                    + rainOverlayMoments(0.7, a) + rainOverlayMoments(0.7, b);
    vec3 actual = applyRainOverlay(background, parameters, true);
    vec3 dry = applyRainOverlay(background, vec4(0.6, 0.12, 0.0, 1.0), true);
    result = vec4(length(actual - expected), length(dry - background),
                  length(actual - background), abs(parameters.r - 0.6) + abs(parameters.g - 0.12));
''')
    assert overlay[..., 0].max() < 0.00001, 'Rain reconstruction differs from alpha composition'
    assert overlay[..., 1].max() == 0.0, 'Dry water changed'
    assert overlay[..., 2].mean() > 0.05, 'Rain has no visible contribution over water'
    assert overlay[..., 3].max() == 0.0, 'Weather overwrites water parameters'

    # Actual vanilla splash texture colours, cyan variant and protected hues.
    palette = run('splash-palette', weather, '''
    int i = int(gl_FragCoord.x);
    vec3 c = vec3(0.0, 54.0, 204.0) / 255.0;
    if (i == 1) c = vec3(24.0, 72.0, 204.0) / 255.0;
    if (i == 2) c = vec3(71.0, 106.0, 204.0) / 255.0;
    if (i == 3) c = vec3(0.0, 0.8, 0.8);
    if (i == 4) c = vec3(1.0);
    if (i == 5) c = vec3(1.0, 0.4, 0.05);
    if (i == 6) c = vec3(0.4, 0.9, 0.85);
    result = vec4(rainParticleWeight(c), rainDropAlbedo());
''', 7, 1)
    assert np.all(palette[0, :4, 0] > 0.999), 'Vanilla splash colours retain cyan'
    assert np.all(palette[0, 4:, 0] == 0.0), 'Unrelated particle hues changed'

    surface = expand(shaders / 'lib/water_surface.glsl', shaders)
    normals = []
    # Footprints in blocks per pixel: fully resolved, partly resolved (finest
    # octave removed), and far grazing water where every octave is unresolved.
    for name, footprint in [('near', '0.01'), ('middle', '0.5'), ('distant', '3.0')]:
        normals.append(run('wave-' + name, surface, '''
    vec2 p = gl_FragCoord.xy * 0.05 - vec2(9.0);
    vec3 normal = waterSurfaceNormal(p, 12.0, FOOTPRINT);
    result = vec4(normal, length(normal));
'''.replace('FOOTPRINT', footprint), 256, 256))
    assert np.abs(normals[0][..., 3] - 1.0).max() < 0.001, 'Normals are not unit length'
    near_slope = float(np.std(normals[0][..., (0, 2)]))
    middle_slope = float(np.std(normals[1][..., (0, 2)]))
    distant_slope = float(np.std(normals[2][..., (0, 2)]))
    assert 0.015 < near_slope < 0.06, 'Near wave slope is outside the calibrated range'
    assert distant_slope < near_slope * 0.1, 'Unresolved waves retain high-frequency slopes'
    assert middle_slope < near_slope, 'Partly resolved water keeps unresolved octaves'
    # Rotated value-noise octaves must stay continuous across their lattice cells.
    continuity = run('wave-continuity', surface, '''
    vec2 p = vec2(gl_FragCoord.x * 0.37 - 40.0, gl_FragCoord.y * 0.91 + 3.0);
    vec3 a = waterSurfaceNormal(p, 12.0, 0.01);
    vec3 b = waterSurfaceNormal(p + vec2(0.0005, 0.0003), 12.0, 0.01);
    result = vec4(length(a - b), 0.0, 0.0, 1.0);
''')
    assert continuity[..., 0].max() < 0.001, 'Wave normals have visible cell seams'
    # A periodic sine sum repeats along the dominant direction; noise must not.
    line = run('wave-periodicity', surface, '''
    float x = gl_FragCoord.x * 0.25;
    result = vec4(waterSurfaceNormal(vec2(x, 0.37 * x), 12.0, 0.01), 1.0);
''', 1024, 1)[0, :, 0]
    line = line - line.mean()
    spectrum = np.abs(np.fft.rfft(line)) ** 2
    peak_share = float(spectrum[1:].max() / spectrum[1:].sum())
    assert peak_share < 0.2, 'Wave normals are dominated by one periodic stripe frequency'
    report = {
        'rain_alpha_composition_max_error': float(overlay[..., 0].max()),
        'dry_water_unchanged': True,
        'water_parameters_preserved': True,
        'splash_palette_matched': True,
        'protected_particle_hues_unchanged': True,
        'near_normal_std': near_slope,
        'middle_normal_std': middle_slope,
        'distant_normal_std': distant_slope,
        'wave_continuity_max_error': float(continuity[..., 0].max()),
        'wave_spectrum_peak_share': peak_share,
        'scope': 'Production GLSL helpers; native client separately verifies draw order and blending',
    }
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
