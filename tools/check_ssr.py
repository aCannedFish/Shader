#!/usr/bin/env python3
"""Check material and water SSR on the macOS GPU with analytic depth scenes.

The fixture stores octahedral RGBA8 normals in RG and depth32 in B. Thin wrappers
read depth with nearest sampling and encode hit UV in the returned radiance; the
production ray traversal and hit validation are unmodified. RGBA16F fixture output
limits hit-UV precision to a fraction of a pixel. This checks geometry, not
reflection filtering, game frame ordering, or hidden/off-screen geometry.
A ray passing just behind a silhouette counts as a hit on the object's side;
a ray passing far behind it must miss. A ray that reaches the depth of a
background covered by a foreground strip hits that background; against the
sky, or with the background removed by the clip plane, it must miss. A
grazing ray on its own floor must never hit, including near the horizon.
Hidden geometry is checked by check_reflection_scene.py.
"""

import argparse
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
from PIL import Image

from check_glsl import FORMAT_TOKENS
from preview.source import expand

WIDTH, HEIGHT = 512, 256
NEAR, FAR = 0.05, 256.0


def unit(vector):
    """Normalize analytic plane and ray vectors in double precision."""
    value = np.asarray(vector, dtype=float)
    return value / np.linalg.norm(value, axis=-1, keepdims=True)


def encode_normal(normal):
    """Match production octahedral encoding and the RGBA8 attachment rounding."""
    normal = np.asarray(normal, dtype=float)
    folded = normal / np.abs(normal).sum(axis=-1, keepdims=True)
    xy = folded[..., :2].copy()
    back = folded[..., 2] < 0
    reflected = (1.0 - np.abs(xy[..., ::-1])) * np.where(xy >= 0, 1.0, -1.0)
    xy = np.where(back[..., None], reflected, xy)
    return np.round((xy * 0.5 + 0.5) * 255) / 255


def glsl_vector(value):
    """Write fixed numeric vectors without locale-dependent shader formatting."""
    return 'vec3(' + ', '.join(f'{float(component):.9f}' for component in value) + ')'


def field(normal, offset, width=WIDTH, height=HEIGHT):
    """Rasterize the visible part of n dot position = offset into a depth field."""
    y, x = np.mgrid[:height, :width]
    rays = np.stack(((2 * (x + 0.5) / width - 1) * width / height,
                     2 * (y + 0.5) / height - 1, -np.ones_like(x)), axis=-1)
    normal = unit(normal)
    denominator = rays @ normal
    distance = np.divide(offset, denominator, out=np.full_like(denominator, FAR),
                         where=np.abs(denominator) > 1e-12)
    depth = FAR / (FAR - NEAR) - FAR * NEAR / ((FAR - NEAR) * np.maximum(distance, NEAR))
    depth[(distance < NEAR) | (distance > FAR)] = 1.0
    pixels = np.ones((height, width, 4), dtype=np.float32)
    pixels[..., :2] = encode_normal(normal)
    pixels[..., 2] = depth
    return pixels


def library(source_path):
    """Expand a current or saved reflection source against repository dependencies."""
    shaders = ROOT / 'shaders'
    source = source_path.read_text()
    source = re.sub(r'^\s*#include\s+"([^"]+)"',
                    lambda match: expand(shaders / 'lib' / match.group(1), shaders),
                    source, flags=re.MULTILINE)
    # The production samplers share one RGBA input in this fixture. Only sampler
    # reads are adapted: depth uses B, normals use RG, and radiance reports hit UV.
    source = source.replace('texture2D(depths,', 'fixtureDepth(depths,')
    source = source.replace('texture2D(depthtex1,', 'fixtureDepth(depthtex1,')
    source = source.replace('texture2D(scene,', 'fixtureColor(scene,')
    source = source.replace('texture2D(colortex6,', 'fixtureColor(colortex6,')
    source = source.replace('textureLod(scene,', 'fixtureColorLod(scene,')
    source = source.replace('textureLod(colortex6,', 'fixtureColorLod(colortex6,')
    source = source.replace('texture2D(', 'texture(')
    if source_path.name == 'water_reflection.glsl':
        # The fixture header already declares the shared parameter sampler.
        source = source.replace('uniform sampler2D colortex1;\n', '')
        # Adapt the shared test calls to the real production water entry point.
        source += '''
vec4 traceMaterialScene(sampler2D scene, sampler2D depths, vec3 origin,
                        vec3 direction, float roughness) {
    float distanceToHit;
    return traceWaterScene(origin, direction, roughness, distanceToHit);
}
'''
    return source


class Probe:
    """Compile minimal stages around production GLSL and read actual GPU results."""

    def __init__(self, work):
        self.work = work
        self.binary = work / 'probe'
        subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                        str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(self.binary)], check=True)

    def run(self, name, pixels, shader_library, body, mips):
        """Run one depth scene; roughness zero makes returned RGB an exact hit UV."""
        source = self.work / (name + '-input.f32')
        target = self.work / (name + '.f32')
        fragment = self.work / (name + '.frag')
        height, width, _ = pixels.shape
        pixels.astype('<f4').tofile(source)
        header = '#version 150\n' + ''.join(f'#define {name} 0\n' for name in FORMAT_TOKENS)
        if mips:
            header += '#define MATERIAL_REFLECTION_MIPS\n'
        header += '''
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D depthtex0;
vec3 sceneSkyBackground(vec2 uv) { return vec3(0.0); }
vec4 fixtureDepth(sampler2D inputTexture, vec2 uv) {
    ivec2 size = textureSize(inputTexture, 0);
    ivec2 pixel = clamp(ivec2(uv * vec2(size)), ivec2(0), size - ivec2(1));
    return vec4(texelFetch(inputTexture, pixel, 0).b);
}
vec4 fixtureColor(sampler2D inputTexture, vec2 uv) {
    return vec4(uv, 0.0, 1.0);
}
vec4 fixtureColorLod(sampler2D inputTexture, vec2 uv, float lod) {
    return fixtureColor(inputTexture, uv);
}
'''
        fragment.write_text(header + shader_library + '\nout vec4 result;\nvoid main() {\n'
                            + 'vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);\n'
                            + body + '\n}\n')
        subprocess.run([str(self.binary), str(width), str(height), str(source), str(target),
                        '1.0', str(fragment)], check=True, stdout=subprocess.DEVNULL)
        output = np.fromfile(target, np.float32).reshape(height, width, 4)
        assert np.isfinite(output).all(), name + ': nonfinite output'
        return output


def silhouette_result(report, key, image, expect_hits, column, row):
    """Thin silhouettes must hit only their own pixel; deep ones must miss."""
    valid = image[..., 3] > 0.001
    count = int(np.count_nonzero(valid))
    entry = {'hits': count, 'max_confidence': float(image[..., 3].max())}
    failed = False
    if expect_hits:
        hits = image[valid][:, :2] * (WIDTH, HEIGHT)
        column_error = float(np.max(np.abs(hits[:, 0] - (column + 0.5)))) if count else None
        entry['silhouette_column_error_pixels'] = column_error
        failed = count == 0 or column_error > 0.5
        if row is not None and count:
            entry['silhouette_row_error_pixels'] = float(np.max(np.abs(hits[:, 1] - (row + 0.5))))
            failed = failed or entry['silhouette_row_error_pixels'] > 0.5
    else:
        failed = count > 0
    report[key] = entry
    return [key] if failed else []


def checks(probe, shader_library, prefix, water=False):
    """Test misses and true intersections, with both opaque and transparent paths."""
    report = {}
    failures = []
    for path in (('water',) if water else ('transparent', 'opaque')):
        mips = path == 'opaque'
        for name, normal, offset in [('floor', (0, 1, 0), -1),
                                     ('wall', (1, 0, 0), -1),
                                     ('tilted', (0.02, 1, -0.01), -1),
                                     ('grazing', (0, 1, 0), -0.3)]:
            image = probe.run(prefix + path + '-' + name, field(normal, offset), shader_library, '''
    float depth = fixtureDepth(depthtex0, uv).r;
    if (depth >= 0.999999) { result = vec4(0.0); return; }
    vec3 normal = decodeNormal(texture(colortex1, uv).rg);
    vec3 position = screenToView(uv, depth);
    vec3 direction = normalize(reflect(normalize(position), normal));
    result = traceMaterialScene(colortex0, depthtex0, position + normal * 0.08,
                                direction, 0.0);
''', mips)
            count = int(np.count_nonzero(image[..., 3] > 0.001))
            key = path + '_self_' + name
            report[key] = {'false_hits': count, 'max_confidence': float(image[..., 3].max())}
            if count:
                failures.append(key)

        # Depth buffers store only front faces. A ray that passes just behind a
        # silhouette enters the side of a solid object, so it must hit exactly at
        # that silhouette. A ray far behind the front face only passes behind it.
        for name, front in (('discontinuity_thin', -5.55), ('discontinuity_deep', -3.0)):
            pixels = field((0, 0, 1), -14)
            pixels[:, WIDTH // 2:] = field((0, 0, 1), front)[:, WIDTH // 2:]
            image = probe.run(prefix + path + '-' + name, pixels, shader_library, '''
    // Before x=0 the visible plane is z=-14, after it the plane is nearer.
    // Each ray reaches x=0 at z=-5.62..-5.90: 0.07..0.35 behind z=-5.55, or
    // more than 2.6 behind z=-3. No finite visible plane is intersected.
    vec3 origin = vec3(-mix(3.1, 4.5, uv.x), mix(-0.5, 0.5, uv.y), -5.0);
    vec3 direction = normalize(vec3(1.0, 0.0, -0.2));
    result = traceMaterialScene(colortex0, depthtex0, origin, direction, 0.0);
''', mips)
            failures += silhouette_result(report, path + '_' + name, image,
                                          name.endswith('thin'), WIDTH // 2, None)

        for name in ('isolated_pixel', 'thin_strip', 'isolated_pixel_deep', 'thin_strip_deep'):
            deep = name.endswith('deep')
            pixels = field((0, 0, 1), -100)
            foreground = field((0, 0, 1), -7.0 if deep else -9.9)
            if name.startswith('isolated_pixel'):
                pixels[HEIGHT // 2, WIDTH // 2] = foreground[HEIGHT // 2, WIDTH // 2]
            else:
                pixels[:, WIDTH // 2] = foreground[:, WIDTH // 2]
            image = probe.run(prefix + path + '-' + name, pixels, shader_library, '''
    // The ray stays at z=-10, parallel to both finite front-facing planes.
    // An isolated foreground pixel cannot borrow its background's depth to
    // construct a tilted plane. At z=-9.9 the ray enters the object's side
    // at the silhouette; at z=-7 it passes far behind the object.
    float centreY = 10.0 / viewHeight;
    vec3 origin = vec3(-mix(2.0, 4.0, uv.x), centreY + mix(-0.024, 0.024, uv.y), -10.0);
    result = traceMaterialScene(colortex0, depthtex0, origin, vec3(1.0, 0.0, 0.0), 0.0);
''', mips)
            failures += silhouette_result(report, path + '_' + name, image, not deep, WIDTH // 2,
                                          HEIGHT // 2 if name.startswith('isolated_pixel') else None)

        for name, normal, offset, origin, direction in [
                ('smooth', (0, 0, 1), -8, (-2, 0, -4), (0.8, 0, -0.6)),
                ('toward_camera', (-0.95, 0, 0.312), -1.872,
                 (-3.2, 0, -8.4), (0.8, 0, 0.6)),
                # Water beside a bank or trunk reflects a wall a few centimetres
                # away. Rejecting such near hits painted a sky band along shores.
                ('near_wall', (1, 0, 0), -1, (-0.9, 0, -5), (-0.7, 0.7, 0))]:
            normal = unit(normal)
            direction = unit(direction)
            distance = (offset - np.dot(normal, origin)) / np.dot(normal, direction)
            hit = np.array(origin) + direction * distance
            expected = hit[:2] / -hit[2] / np.array((WIDTH / HEIGHT, 1)) * 0.5 + 0.5
            body = ('result = traceMaterialScene(colortex0, depthtex0, '
                    + glsl_vector(origin) + ', ' + glsl_vector(direction) + ', 0.0);')
            image = probe.run(prefix + path + '-' + name, field(normal, offset),
                              shader_library, body, mips)
            actual = image[HEIGHT // 2, WIDTH // 2]
            error = (float(np.max(np.abs(actual[:2] - expected) * (WIDTH, HEIGHT)))
                     if actual[3] >= 0.5 else None)
            key = path + '_' + name
            report[key] = {'confidence': float(actual[3]), 'hit_error_pixels': error}
            if actual[3] < 0.5 or error > 0.5:
                failures.append(key)
    # Covered background: a z=-7 strip hides part of a z=-12 plane. A ray that
    # passes far behind the strip and reaches the plane's depth there hits the
    # background (a hill seen through leaves) at the pixel where it was covered.
    # Against the sky, or with the background clipped away (riverbed below the
    # water plane), screen space must not guess an occluder and every ray misses.
    for name, background, direction, plane, expected in [
            ('covered_background', -12, (1.0, 0.0, -0.5), '0.0', True),
            ('covered_clipped', -12, (1.0, 0.0, -0.5), '1.0', False),
            ('covered_canopy_sky', None, (1.0, 0.0, -0.5), '0.0', False),
            ('covered_pole_sky', None, (1.0, 0.0, 0.0), '0.0', False)]:
        pixels = field((0, 0, 1), background) if background else np.ones((HEIGHT, WIDTH, 4), np.float32)
        if background is None:
            pixels[..., :2] = encode_normal(np.array((0.0, 0.0, 1.0)))
        strip = 6 if name.endswith('pole_sky') else 40
        pixels[:, WIDTH // 2:WIDTH // 2 + strip] = field((0, 0, 1), -7.0)[:, WIDTH // 2:WIDTH // 2 + strip]
        image = probe.run(prefix + name, pixels, shader_library, '''
    // Rays start at z=-10 and reach x=0 (the strip edge) 3.5-4.5 behind the strip.
    // Sloped rays reach z=-12 at x=1..3, still behind the 40-pixel strip.
    // The clip plane z=-11 removes the background, as water removes the riverbed.
    vec3 origin = vec3(-mix(1.0, 3.0, uv.x), mix(-0.3, 0.3, uv.y), -10.0);
    bool thinHit;
    vec4 hit = traceScreenReflection(depthtex0, origin, normalize(''' + glsl_vector(direction) + '''),
                                     0.0, far, 32, vec4(0.0, 0.0, ''' + plane + ''', 11.0 * ''' + plane + '''),
                                     thinHit);
    result = vec4(hit.xy * vec2(viewWidth, viewHeight), hit.z, hit.a);
''', False)
        valid = image[..., 3] > 0.001
        count = int(np.count_nonzero(valid))
        entry = {'hits': count}
        if expected:
            columns = image[..., 0][valid]
            distances = image[..., 2][valid]
            # Background pixels lie left of the strip; the coarse step can record
            # the covering a few pixels early. The ray reaches z=-12 after 4.47 units.
            entry['column_range'] = [float(columns.min()), float(columns.max())] if count else None
            entry['distance_range'] = [float(distances.min()), float(distances.max())] if count else None
            failed = (count < valid.size * 0.95 or columns.max() > WIDTH // 2
                      or columns.min() < WIDTH // 2 - 12 or np.abs(distances - 4.4721).max() > 0.6)
        else:
            failed = count > 0
        report[name] = entry
        if failed:
            failures.append(name)

    if not water:
        image = probe.run(prefix + 'opaque-extreme-grazing',
                          field((0, 1, 0), -0.3, width=1024, height=2048), shader_library, '''
    // Match high vertical pixel density, while tracing only one row of rays.
    // At these shallow angles RGBA8 normal error can point the ray back into
    // its receiver, even when the true geometric depth normal is accurate.
    if (gl_FragCoord.y > 1.0) { result = vec4(0.0); return; }
    vec3 normal = decodeNormal(texture(colortex1, vec2(0.5)).rg);
    float z = mix(35.0, 130.0, uv.x);
    vec3 position = vec3(z * 0.4, -0.3, -z);
    vec3 direction = normalize(reflect(normalize(position), normal));
    result = traceMaterialScene(colortex0, depthtex0, position + normal * 0.08,
                                direction, 0.0);
''', True)
        count = int(np.count_nonzero(image[..., 3] > 0.001))
        key = 'opaque_self_extreme_grazing'
        report[key] = {'false_hits': count, 'tested_rays': 1024,
                       'max_confidence': float(image[..., 3].max())}
        if count:
            failures.append(key)
    return {'checks': report, 'failed_checks': failures}


def dense_checks(probe, shader_library, prefix, water=False):
    """Require continuous ray families to retain their analytic plane crossings.

    A few fixed rays do not reveal alternating hit/fallback decisions. Here each
    output pixel changes the origin, direction and true hit position smoothly.
    All rays start in front of the plane and cross it within the visible image.
    """
    report = {}
    failures = []
    variants = [(1024, 512, 32), (1024, 512, 24), (1920, 1080, 24)]
    for path in (('water',) if water else ('transparent', 'opaque')):
        for width, height, bits in variants:
            # Floating depth near 1 already has roughly 24 bits of precision;
            # explicit fixed-point rounding also covers depth24 attachments.
            pixels = field((-0.8, 0.15, 0.58), -5, width, height)
            if bits == 24:
                pixels[..., 2] = np.round(pixels[..., 2].astype(float) * (2 ** 24 - 1)) / (2 ** 24 - 1)
            y, x = np.mgrid[:height, :width]
            uv = np.stack(((x + 0.5) / width, (y + 0.5) / height), axis=-1)
            expected = np.array((0.44, 0.35)) + uv * np.array((0.33, 0.30))
            camera_ray = np.concatenate(((expected * 2 - 1) * (width / height, 1),
                                         -np.ones((height, width, 1))), axis=-1)
            normal = unit((-0.8, 0.15, 0.58))
            hit = camera_ray * (-5 / (camera_ray @ normal))[..., None]
            direction = unit(np.stack((0.7 + 0.2 * uv[..., 1], 0.08 + 0.06 * uv[..., 0],
                                       -0.5 + 0.1 * uv[..., 0]), axis=-1))
            distance = 2.5 + 1.5 * uv[..., 1]
            origin = hit - direction * distance[..., None]
            origin_uv = origin[..., :2] / -origin[..., 2, None] / (width / height, 1) * 0.5 + 0.5
            assert (origin[..., 2] < -NEAR).all(), 'Dense fixture starts behind the camera'
            assert ((origin_uv > 0.002) & (origin_uv < 0.998)).all(), 'Dense origin leaves the screen'
            assert (origin @ normal > -5).all() and (direction @ normal < 0).all()
            image = probe.run(prefix + path + f'-dense-{width}-{bits}', pixels, shader_library, '''
    vec2 targetUv = mix(vec2(0.44, 0.35), vec2(0.77, 0.65), uv);
    vec3 normal = normalize(vec3(-0.8, 0.15, 0.58));
    vec3 cameraRay = vec3((targetUv * 2.0 - 1.0) * vec2(viewWidth / viewHeight, 1.0), -1.0);
    vec3 hit = cameraRay * (-5.0 / dot(normal, cameraRay));
    // Keep the ray above its origin, as a water reflection also requires.
    vec3 direction = normalize(vec3(0.7 + 0.2 * uv.y, 0.08 + 0.06 * uv.x, -0.5 + 0.1 * uv.x));
    vec3 origin = hit - direction * (2.5 + 1.5 * uv.y);
    result = traceMaterialScene(colortex0, depthtex0, origin, direction, 0.0);
''', path == 'opaque')
            valid = image[..., 3] > 0.5
            error = np.max(np.abs(image[..., :2] - expected) * (width, height), axis=-1)
            coverage = float(valid.mean())
            maximum = float(error[valid].max()) if valid.any() else None
            key = path + f'_dense_{width}_depth{bits}'
            report[key] = {'coverage': coverage, 'misses': int((~valid).sum()),
                           'tested_rays': width * height, 'max_error_pixels': maximum,
                           'p99_error_pixels': float(np.percentile(error[valid], 99)) if valid.any() else None}
            Image.fromarray(np.uint8(valid * 255)).save(probe.work / (prefix + key + '-coverage.png'))
            if coverage < 0.999 or maximum is None or maximum > 1.0:
                failures.append(key)
    return {'checks': report, 'failed_checks': failures}


def complete_checks(probe, shader_library, prefix, water=False, dense_only=False):
    """Combine sparse edge cases with dense coverage without hiding either result."""
    result = dense_checks(probe, shader_library, prefix, water=water)
    if not dense_only:
        sparse = checks(probe, shader_library, prefix, water=water)
        result['checks'].update(sparse['checks'])
        result['failed_checks'].extend(sparse['failed_checks'])
    return result


def main():
    """Optionally compare a saved old traversal on precisely the same GPU scenes."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-reflection', type=Path,
                        help='Saved old material_reflection.glsl to compare against current source')
    parser.add_argument('--report-only', action='store_true', help='Print failures without nonzero exit')
    parser.add_argument('--dense-only', action='store_true', help='Run only continuous valid-plane coverage')
    args = parser.parse_args()
    work = ROOT / '.preview/ssr-verification'
    work.mkdir(parents=True, exist_ok=True)
    probe = Probe(work)
    report = {'scope': __doc__.strip()}
    if args.baseline_reflection:
        report['baseline'] = complete_checks(probe, library(args.baseline_reflection.resolve()),
                                              'baseline-', dense_only=args.dense_only)
    report['current'] = complete_checks(probe, library(ROOT / 'shaders/lib/material_reflection.glsl'),
                                        'current-', dense_only=args.dense_only)
    report['water'] = complete_checks(probe, library(ROOT / 'shaders/lib/water_reflection.glsl'),
                                      'water-', water=True, dense_only=args.dense_only)
    (work / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    failures = report['current']['failed_checks'] + report['water']['failed_checks']
    if failures and not args.report_only:
        raise SystemExit('SSR regression: ' + ', '.join(failures))


if __name__ == '__main__':
    main()
