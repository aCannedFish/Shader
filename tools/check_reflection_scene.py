#!/usr/bin/env python3
"""Compare production water reflections with a voxel-scene ground truth.

A small Minecraft-like scene (hill, trees with cutout leaves, an island tree
overhanging the water and a plank bridge) is ray traced in numpy. The main
view supplies colour and opaque depth; a shadow map is cast with the production
distortion. Each water pixel's reflected ray is traced in the voxel scene for
the reference, and the production GLSL reflection runs on the GPU probe with
the same colour, depth and shadow-map inputs.

The reference shades hidden faces with the same simple light model; production
can only approximate them. The metrics therefore classify sky against geometry
and count strong darkening or brightening, instead of demanding equal colour.
Waves, roughness filtering of real textures and game frame order are not covered.
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

WIDTH, HEIGHT = 960, 480
NEAR, FAR = 0.05, 256.0
CAMERA = np.array([0.0, 80.0, 0.0])
WATER_Y = 76.9
SUN = np.array([70.0, 35.0, 0.0]) / np.linalg.norm([70.0, 35.0, 0.0])
SHADOW_RESOLUTION = 2048
SHADOW_DISTANCE = 96.0
SHADOW_BIAS = 0.95
LOW = np.array([-48, 56, -96])
SIZE = np.array([96, 48, 104])
AIR, GROUND, TRUNK, LEAVES, PLANKS, SAND = range(6)
ALBEDO = {GROUND: (0.30, 0.42, 0.16), TRUNK: (0.34, 0.25, 0.15), LEAVES: (0.14, 0.36, 0.10),
          PLANKS: (0.58, 0.44, 0.27), SAND: (0.55, 0.50, 0.38)}
HORIZON = np.array([0.72, 0.82, 1.00])
ZENITH = np.array([0.22, 0.40, 0.90])


def build_scene():
    """Voxelize the shore, river bed, hill, trees and bridge."""
    grid = np.zeros(SIZE, np.uint8)
    x, z = np.meshgrid(np.arange(LOW[0], LOW[0] + SIZE[0]), np.arange(LOW[2], LOW[2] + SIZE[2]),
                       indexing='ij')
    top = np.full(x.shape, 73)
    top[z >= -2] = 76
    # 远处山体：坡度随 x 起伏，最高处高于相机。
    hill = 77 + np.floor((-26 - z) * 0.85 + 2.5 * np.sin(x * 0.21) + 1.5 * np.cos(x * 0.13 + z * 0.3))
    top = np.where(z <= -26, np.maximum(top, np.minimum(hill, 99)).astype(int), top)
    island = (np.abs(x + 15) <= 1) & (np.abs(z + 8) <= 1)
    top[island] = 76
    for ix in range(SIZE[0]):
        for iz in range(SIZE[2]):
            height = int(top[ix, iz]) - LOW[1]
            grid[ix, :height + 1, iz] = GROUND
            if top[ix, iz] <= 73:
                grid[ix, height, iz] = SAND

    def tree(tx, tz, trunk_height):
        base = int(top[tx - LOW[0], tz - LOW[2]]) + 1
        for y in range(base, base + trunk_height):
            grid[tx - LOW[0], y - LOW[1], tz - LOW[2]] = TRUNK
        for dy in range(trunk_height - 2, trunk_height + 2):
            radius = 2 if dy < trunk_height else 1
            for dx in range(-radius, radius + 1):
                for dz in range(-radius, radius + 1):
                    if radius == 2 and abs(dx) == 2 and abs(dz) == 2 and dy == trunk_height - 1:
                        continue
                    cell = (tx + dx - LOW[0], base + dy - LOW[1], tz + dz - LOW[2])
                    if grid[cell] == AIR:
                        grid[cell] = LEAVES

    for tx, tz in [(-22, -28), (-12, -27), (-3, -29), (7, -27), (16, -28), (25, -30), (-30, -33)]:
        tree(tx, tz, 5)
    tree(-15, -8, 4)
    # 桥面低于相机，相机只看到顶面；水面倒影应看到不受日照的底面。
    grid[2 - LOW[0]:13 - LOW[0], 78 - LOW[1], -14 - LOW[2]:-10 - LOW[2]] = PLANKS
    return grid


def leaf_opaque(u, v):
    """All leaves share one 16x16 cutout texture, about 30 percent holes."""
    tu = np.floor(np.clip(u, 0, 0.9999) * 16).astype(np.int64)
    tv = np.floor(np.clip(v, 0, 0.9999) * 16).astype(np.int64)
    value = (tu * 374761393 + tv * 668265263) & 0xffffffff
    value = ((value ^ (value >> 13)) * 1274126177) & 0xffffffff
    return (value & 0xffff) / 65535.0 >= 0.3


def trace(grid, origin, direction, limit=400.0):
    """Amanatides-Woo traversal; returns t, material and face normal per ray."""
    count = len(direction)
    origin = np.broadcast_to(origin, direction.shape).astype(float)
    safe = np.where(np.abs(direction) < 1e-12, 1e-12, direction)
    inverse = 1.0 / safe
    low, high = LOW.astype(float), (LOW + SIZE).astype(float)
    near = np.minimum((low - origin) * inverse, (high - origin) * inverse)
    farther = np.maximum((low - origin) * inverse, (high - origin) * inverse)
    entry = np.max(near, axis=1)
    exit_t = np.min(farther, axis=1)
    start = np.maximum(entry, 0.0)
    t_hit = np.full(count, np.inf)
    material = np.zeros(count, np.uint8)
    normal = np.zeros((count, 3))
    active = np.nonzero(exit_t > start)[0]
    point = origin[active] + direction[active] * (start[active, None] + 1e-6)
    voxel = np.clip(np.floor(point).astype(np.int64), LOW, LOW + SIZE - 1)
    # 与 inverse 同号：分量为 0 的方向（正交日光）不能在第一步就跨格。
    step = np.where(safe[active] > 0, 1, -1)
    next_t = (voxel + (step > 0) - origin[active]) * inverse[active]
    delta = np.abs(inverse[active])
    t_entry = start[active].copy()
    axis = np.where(entry[active] > 0, np.argmax(near[active], axis=1), -1)
    while len(active):
        cell = grid[tuple((voxel - LOW).T)]
        hit = (cell != AIR) & (cell != LEAVES)
        leaf = cell == LEAVES
        if np.any(leaf):
            index = np.nonzero(leaf)[0]
            p = origin[active[index]] + direction[active[index]] * t_entry[index, None]
            a = axis[index]
            u = np.where(a == 0, p[:, 2], p[:, 0]) % 1.0
            v = np.where(a == 1, p[:, 2], p[:, 1]) % 1.0
            hit[index] = leaf_opaque(u, v) & (a >= 0)
        if np.any(hit):
            index = np.nonzero(hit)[0]
            rays = active[index]
            t_hit[rays] = t_entry[index]
            material[rays] = cell[index]
            a = axis[index]
            n = np.zeros((len(index), 3))
            n[np.arange(len(index)), np.maximum(a, 0)] = -step[index, np.maximum(a, 0)]
            normal[rays] = n
        a = np.argmin(next_t, axis=1)
        rows = np.arange(len(active))
        t_entry = next_t[rows, a]
        voxel[rows, a] += step[rows, a]
        next_t[rows, a] += delta[rows, a]
        axis = a
        inside = np.all((voxel >= LOW) & (voxel < LOW + SIZE), axis=1)
        keep = ~hit & inside & (t_entry < limit)
        active, voxel, step, next_t, delta, t_entry, axis = (
            active[keep], voxel[keep], step[keep], next_t[keep], delta[keep], t_entry[keep], axis[keep])
    return t_hit, material, normal


def sky(direction):
    """Analytic sky shared with the GLSL fixture."""
    y = np.clip(direction[:, 1], 0.0, 1.0)[:, None]
    return HORIZON + (ZENITH - HORIZON) * np.sqrt(y)


def shade(grid, points, normals, materials):
    """Lambert sun with a traced shadow plus face-dependent sky ambient."""
    albedo = np.array([ALBEDO.get(int(m), (0, 0, 0)) for m in range(6)])[materials]
    top = (materials == GROUND) & (normals[:, 1] < 0.5)
    albedo[top] = (0.40, 0.30, 0.20)
    lit = np.clip(normals @ SUN, 0.0, None)
    visible = np.zeros(len(points))
    index = np.nonzero(lit > 0)[0]
    if len(index):
        t, _, _ = trace(grid, points[index] + normals[index] * 1e-4, np.tile(SUN, (len(index), 1)))
        visible[index] = np.isinf(t)
    ambient = 0.30 + 0.12 * normals[:, 1]
    light = ambient[:, None] * np.array([0.60, 0.70, 1.00]) + (lit * visible)[:, None] * np.array([2.0, 1.9, 1.7])
    return albedo * light


def view_rays():
    """Probe camera: identity view, 90 degree vertical field of view."""
    y, x = np.mgrid[:HEIGHT, :WIDTH]
    rays = np.stack(((2 * (x + 0.5) / WIDTH - 1) * WIDTH / HEIGHT,
                     2 * (y + 0.5) / HEIGHT - 1, -np.ones_like(x, dtype=float)), axis=-1)
    return rays.reshape(-1, 3).astype(float)


def render(grid):
    """Main view colour, opaque depth, water mask and reference reflection."""
    rays = view_rays()
    directions = rays / np.linalg.norm(rays, axis=1, keepdims=True)
    t, material, normal = trace(grid, CAMERA, directions)
    hit = np.isfinite(t)
    points = CAMERA + directions * t[:, None]
    colour = sky(directions)
    colour[hit] = shade(grid, points[hit], normal[hit], material[hit])
    view_depth = np.where(hit, t * -directions[:, 2], FAR)
    depth = FAR / (FAR - NEAR) - FAR * NEAR / ((FAR - NEAR) * np.maximum(view_depth, NEAR))
    depth[~hit | (view_depth > FAR)] = 1.0

    # 水面：视线先到达水平面且下方是河床（不是岛屿、岸或山体）。
    water_t = np.where(directions[:, 1] < 0, (WATER_Y - CAMERA[1]) / np.minimum(directions[:, 1], -1e-9), np.inf)
    water_points = CAMERA + directions * water_t[:, None]
    cell = np.floor(water_points).astype(np.int64)
    cell[:, 1] = 76
    inside = np.all((cell >= LOW) & (cell < LOW + SIZE), axis=1)
    water = inside & (water_t < t)
    index = np.nonzero(water)[0]
    column = cell[index] - LOW
    water[index] = grid[column[:, 0], column[:, 1], column[:, 2]] == AIR
    index = np.nonzero(water)[0]
    reflected = directions[index] * np.array([1.0, -1.0, 1.0])
    origins = water_points[index] + np.array([0.0, 1e-4, 0.0])
    rt, rm, rn = trace(grid, origins, reflected)
    rhit = np.isfinite(rt)
    truth = sky(reflected)
    rpoints = origins + reflected * rt[:, None]
    truth[rhit] = shade(grid, rpoints[rhit], rn[rhit], rm[rhit])
    truth_full = np.zeros((len(rays), 3))
    truth_full[index] = truth
    geometry = np.zeros(len(rays), bool)
    geometry[index] = rhit
    hidden = np.zeros(len(rays), bool)
    # 倒影命中的面若背对相机（或被遮挡），屏幕里没有它的颜色。
    hidden[index] = rhit & (np.einsum('ij,ij->i', rn, CAMERA - rpoints) <= 0)
    shape = (HEIGHT, WIDTH)
    return (colour.reshape(*shape, 3), depth.reshape(shape), water.reshape(shape),
            truth_full.reshape(*shape, 3), geometry.reshape(shape), hidden.reshape(shape))


def shadow_matrices():
    """Player-relative shadow view 100 blocks towards the sun and its ortho projection."""
    ez = SUN
    ex = np.array([0.0, 0.0, 1.0])
    ey = np.cross(ez, ex)
    view = np.eye(4)
    view[:3, :3] = np.stack((ex, ey, ez))
    view[2, 3] = -100.0
    near, far = 0.05, 256.0
    projection = np.diag([1.0 / SHADOW_DISTANCE, 1.0 / SHADOW_DISTANCE, -2.0 / (far - near), 1.0])
    projection[2, 3] = -(far + near) / (far - near)
    return view, projection


def shadow_map(grid):
    """Cast the opaque shadow depth for each distorted texel centre."""
    view, projection = shadow_matrices()
    coordinate = (np.arange(SHADOW_RESOLUTION) + 0.5) / SHADOW_RESOLUTION * 2 - 1
    gy, gx = np.meshgrid(coordinate, coordinate, indexing='ij')
    distorted = np.stack((gx, gy), axis=-1).reshape(-1, 2)
    length = np.linalg.norm(distorted, axis=1, keepdims=True)
    clip = distorted * (1 - SHADOW_BIAS) / np.maximum(1 - SHADOW_BIAS * length, 1e-6)
    depth = np.ones(len(clip))
    valid = np.all(np.abs(clip) <= 1, axis=1)
    inverse_view = np.linalg.inv(view)
    shadow_xy = clip[valid] * SHADOW_DISTANCE
    # 从阴影相机平面（z = -0.05）沿 -SUN 投射。
    start = np.concatenate((shadow_xy, np.full((len(shadow_xy), 1), -0.05), np.ones((len(shadow_xy), 1))), axis=1)
    world = (inverse_view @ start.T).T[:, :3] + CAMERA
    t, _, _ = trace(grid, world, np.tile(-SUN, (len(world), 1)), limit=256.0)
    shadow_z = -0.05 - t
    clip_z = projection[2, 2] * shadow_z + projection[2, 3]
    values = np.where(np.isfinite(t), np.clip(clip_z * 0.5 + 0.5, 0, 1), 1.0)
    depth[np.nonzero(valid)[0]] = values
    return depth.reshape(SHADOW_RESOLUTION, SHADOW_RESOLUTION), view, projection


def library():
    """Expand the production water reflection with fixture sampler adapters."""
    shaders = ROOT / 'shaders'
    source = (shaders / 'lib/water_reflection.glsl').read_text()
    source = re.sub(r'^\s*#include\s+"([^"]+)"',
                    lambda match: expand(shaders / 'lib' / match.group(1), shaders),
                    source, flags=re.MULTILINE)
    source = source.replace('texture2D(depths,', 'fixtureDepth(depths,')
    source = source.replace('texture2D(depthtex1,', 'fixtureDepth(depthtex1,')
    source = source.replace('texture2D(colortex6,', 'fixtureColor(colortex6,')
    source = source.replace('textureLod(colortex6,', 'fixtureColorLod(colortex6,')
    source = source.replace('textureLod(scene,', 'fixtureColorLod(scene,')
    source = source.replace('texture2D(', 'texture(')
    source = source.replace('uniform sampler2D colortex1;\n', '')
    return source


HEADER = '''
uniform sampler2D colortex1;
vec3 sceneSkyBackground(vec2 uv) { return vec3(0.0); }
vec4 fixtureDepth(sampler2D inputTexture, vec2 uv) {
    ivec2 size = textureSize(inputTexture, 0);
    ivec2 pixel = clamp(ivec2(uv * vec2(size)), ivec2(0), size - ivec2(1));
    return vec4(texelFetch(inputTexture, pixel, 0).a);
}
vec4 fixtureColor(sampler2D inputTexture, vec2 uv) {
    return vec4(texture(inputTexture, uv).rgb, 1.0);
}
vec4 fixtureColorLod(sampler2D inputTexture, vec2 uv, float lod) {
    return vec4(textureLod(inputTexture, uv, lod).rgb, 1.0);
}
'''

BODY = '''
vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
vec3 ray = normalize(screenToView(uv, 0.9));
if (ray.y >= -1.0e-5) { result = vec4(0.0, 0.0, 0.0, -1.0); return; }
vec3 position = ray * ((WATER_LEVEL - cameraPosition.y) / ray.y);
vec3 normal = vec3(0.0, 1.0, 0.0);
vec3 direction = normalize(reflect(normalize(position), normal));
vec3 rayWorld = normalize(mat3(gbufferModelViewInverse) * direction);
rayWorld.y = abs(rayWorld.y);
vec3 environment = mix(HORIZON, ZENITH, sqrt(clamp(rayWorld.y, 0.0, 1.0)));
float distanceToHit;
FIXTURE_TRACE
result = vec4(mix(environment, screen.rgb, screen.a), skyFraction);
'''

# 旧接口：遮挡物颜色由屏幕空间光线给出。
TRACE_OCCLUDER = '''
vec4 occluder;
vec4 screen = traceWaterScene(position + normal * 0.08, direction, ROUGHNESS, distanceToHit, occluder);
environment = mix(environment, occluder.rgb, occluder.a);
float skyFraction = (1.0 - screen.a) * (1.0 - occluder.a);
'''

# 新接口：屏幕命中之外由阴影图遮挡判断补足。
TRACE_OCCLUSION = '''
vec4 screen = traceWaterScene(position + normal * 0.08, direction, ROUGHNESS, distanceToHit);
float occlusionDistance;
vec4 occlusion = waterReflectionOcclusion(position, direction, SKY_LEVEL, occlusionDistance);
if (reflectionOcclusionCloser(occlusion, occlusionDistance, distanceToHit)) {
    screen.a = 0.0;
}
environment = mix(environment, occlusion.rgb, occlusion.a);
float skyFraction = (1.0 - screen.a) * (1.0 - occlusion.a);
'''

# 调试：r = 屏幕命中权重，g = 阴影图遮挡，b = 遮挡面相机不可见。
TRACE_DEBUG = '''
vec4 screen = traceWaterScene(position + normal * 0.08, direction, ROUGHNESS, distanceToHit);
bool hiddenFace;
vec4 occlusion = reflectionShadowOcclusion(depthtex1, position, direction, hiddenFace);
screen = vec4(screen.a, occlusion.w, hiddenFace ? 1.0 : 0.0, 1.0);
float skyFraction = 0.0;
'''


def luma(colour):
    return colour @ np.array([0.2126, 0.7152, 0.0722])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.preview/reflection-scene')
    parser.add_argument('--roughness', type=float, default=0.25)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--assert-targets', action='store_true', help='Fail on migration geometry/colour targets')
    parser.add_argument('--debug', action='store_true', help='write debug.png with hit classes')
    arguments = parser.parse_args()
    work = arguments.output
    work.mkdir(parents=True, exist_ok=True)

    grid = build_scene()
    colour, depth, water, truth, geometry, hidden = render(grid)
    from preview.migration_reference import water_reference
    np.savez_compressed(work / 'reference-hits.npz', **water_reference(grid, water))
    shadow, view, projection = shadow_map(grid)

    pixels = np.zeros((HEIGHT, WIDTH, 4), np.float32)
    pixels[..., :3] = colour
    pixels[..., 3] = depth
    pixels.astype('<f4').tofile(work / 'scene.f32')
    second = np.zeros((SHADOW_RESOLUTION, SHADOW_RESOLUTION, 4), np.float32)
    second[..., 0] = shadow
    second.astype('<f4').tofile(work / 'shadow.f32')
    lines = [f'vec3 shadowLightPosition {SUN[0] * 100} {SUN[1] * 100} {SUN[2] * 100}',
             'vec3 skyColor 0.47 0.65 1.0']
    for name, matrix in (('shadowModelView', view), ('shadowProjection', projection),
                         ('shadowModelViewInverse', np.linalg.inv(view)),
                         ('shadowProjectionInverse', np.linalg.inv(projection))):
        lines.append(f'mat4 {name} ' + ' '.join(f'{value:.9g}' for value in matrix.T.reshape(-1)))
    (work / 'uniforms.txt').write_text('\n'.join(lines) + '\n')

    source = library()
    trace_code = TRACE_OCCLUSION if 'waterReflectionOcclusion(' in source else TRACE_OCCLUDER
    if arguments.debug:
        trace_code = TRACE_DEBUG
    header = '#version 150\n' + ''.join(f'#define {name} 0\n' for name in FORMAT_TOKENS)
    constants = (f'const float WATER_LEVEL = {WATER_Y};\nconst float ROUGHNESS = {arguments.roughness};\n'
                 f'const float SKY_LEVEL = 1.0;\n'
                 f'const vec3 HORIZON = vec3({HORIZON[0]}, {HORIZON[1]}, {HORIZON[2]});\n'
                 f'const vec3 ZENITH = vec3({ZENITH[0]}, {ZENITH[1]}, {ZENITH[2]});\n')
    fragment = work / 'reflection.frag'
    fragment.write_text(header + HEADER + source + constants + '\nout vec4 result;\nvoid main() {\n'
                        + BODY.replace('FIXTURE_TRACE', trace_code) + '}\n')
    binary = work / 'probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/bloom_probe.c'), '-o', str(binary)], check=True)
    environment = dict(os.environ, SIMPLESHADER_PROBE_UNIFORMS=str(work / 'uniforms.txt'),
                       SIMPLESHADER_PROBE_SECOND=f'{work / "shadow.f32"} {SHADOW_RESOLUTION} {SHADOW_RESOLUTION}')
    timing = subprocess.run([str(binary), str(WIDTH), str(HEIGHT), str(work / 'scene.f32'),
                             str(work / 'result.f32'), '1.0', str(fragment)],
                            check=True, env=environment, capture_output=True, text=True).stdout
    output = np.fromfile(work / 'result.f32', np.float32).reshape(HEIGHT, WIDTH, 4)
    assert np.isfinite(output).all(), 'nonfinite output'

    shader = output[..., :3]
    if arguments.debug:
        debug = np.zeros((HEIGHT, WIDTH, 3), np.uint8)
        debug[water] = (np.clip(shader[water], 0, 1) * 255).astype(np.uint8)
        Image.fromarray(debug[::-1]).save(work / 'debug.png')
        return
    sky_fraction = output[..., 3]
    truth_luma = luma(truth)
    shader_luma = luma(shader)
    leak = water & geometry & (sky_fraction > 0.5)
    false_occlusion = water & ~geometry & (sky_fraction < 0.5)
    dark = water & (shader_luma < truth_luma * 0.55)
    bright = water & (shader_luma > truth_luma * 1.8)
    error = np.abs(shader_luma - truth_luma)[water]
    report = {
        'water_pixels': int(water.sum()),
        'truth_geometry': int((water & geometry).sum()),
        'truth_hidden_face': int((water & hidden).sum()),
        'geometry_hit_rate': 1.0 - float(leak.sum()) / max(int((water & geometry).sum()), 1),
        'wrong_sky_fraction': float(leak.sum()) / max(int((water & geometry).sum()), 1),
        'unknown_fraction': None,
        'classification_scope': 'Legacy output exposes sky weight, not explicit hit/unknown; full nearest-hit validation remains pending P07',
        'sky_leak': int(leak.sum()),
        'false_occlusion': int(false_occlusion.sum()),
        'dark': int(dark.sum()),
        'bright': int(bright.sum()),
        'mean_luma_error': float(error.mean()),
        'interface': 'shadow-map occlusion' if trace_code is TRACE_OCCLUSION else 'screen occluder',
        'probe': json.loads(timing.strip().splitlines()[-1]),
    }

    def image(array):
        value = np.clip(array / (1 + array), 0, 1) ** (1 / 2.2)
        return Image.fromarray((value[::-1] * 255).astype(np.uint8))

    composite = colour.copy()
    composite[water] = shader[water]
    image(colour).save(work / 'view.png')
    reference = colour.copy()
    reference[water] = truth[water]
    image(reference).save(work / 'truth.png')
    image(composite).save(work / 'shader.png')
    marks = np.zeros((HEIGHT, WIDTH, 3), np.uint8)
    marks[leak] = (0, 120, 255)
    marks[false_occlusion] = (255, 0, 255)
    marks[dark & ~leak] = (255, 40, 0)
    marks[bright & ~leak] = (255, 255, 0)
    Image.fromarray(marks[::-1]).save(work / 'errors.png')
    failures = []
    if report['unknown_fraction'] is None: failures.append('explicit_unknown_reporting')
    if report['geometry_hit_rate'] < 0.99: failures.append('geometry_hit_rate')
    if report['wrong_sky_fraction'] >= 0.005: failures.append('wrong_sky_fraction')
    if int(dark.sum()) / max(int((water & geometry).sum()), 1) > 0.01: failures.append('excessive_darkening')
    if int(bright.sum()) / max(int(water.sum()), 1) > 0.01: failures.append('excessive_brightening')
    report['failed_targets'] = failures
    (work / 'verification.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=None if arguments.json else 2))
    if arguments.assert_targets and failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
