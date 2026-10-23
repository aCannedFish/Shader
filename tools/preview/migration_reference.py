"""Independent voxel oracle with first-hit attributes and layered glass absorption.

This module uses the CPU scene traversal, never production GLSL or GPU caches.
Outside the finite fixture is defined as empty sky; that convention is explicit
and does not grant the production renderer the same knowledge.
"""
import numpy as np
import check_reflection_scene as fixture

SURFACE = 1
SKY = 2
STEP_LIMIT = 3


def trace_reference(grid, origins, directions, glass_material=None, sigma=None):
    """Return nearest opaque/cutout hit plus distance, UV, normal and RGB transfer."""
    directions = np.asarray(directions, dtype=float)
    directions /= np.linalg.norm(directions, axis=-1, keepdims=True)
    start = np.broadcast_to(np.asarray(origins, dtype=float), directions.shape).copy()
    points = start.copy()
    count = len(directions)
    distance = np.zeros(count)
    transmission = np.ones((count, 3))
    material = np.zeros(count, np.uint8)
    normal = np.zeros((count, 3))
    state = np.full(count, STEP_LIMIT, np.uint8)
    active = np.arange(count)
    for _ in range(8):
        if not len(active):
            break
        t, m, n = fixture.trace(grid, points[active], directions[active])
        hit = np.isfinite(t)
        missed = active[~hit]
        state[missed] = SKY
        distance[missed] = -1.0
        found = active[hit]
        if not len(found):
            active = found
            continue
        location = points[found] + directions[found] * t[hit, None]
        distance[found] += t[hit]
        transparent = m[hit] == glass_material if glass_material is not None else np.zeros(len(found), bool)
        solid = found[~transparent]
        state[solid] = SURFACE
        material[solid] = m[hit][~transparent]
        normal[solid] = n[hit][~transparent]
        points[solid] = location[~transparent]
        active = found[transparent]
        if len(active):
            inside = location[transparent] + directions[active] * 1e-5
            direction = directions[active]
            boundary = np.floor(inside) + (direction > 0)
            delta = np.divide(boundary - inside, direction,
                              out=np.full_like(direction, np.inf), where=abs(direction) > 1e-10)
            thickness = np.min(delta, axis=-1) + 1e-5
            transmission[active] *= np.exp(-np.asarray(sigma) * thickness[:, None])
            points[active] = inside + direction * (thickness[:, None] + 1e-5)
            distance[active] += thickness + 2e-5
    axis = np.argmax(abs(normal), axis=-1)
    uv = np.stack((np.where(axis == 0, points[:, 2], points[:, 0]),
                   np.where(axis == 1, points[:, 2], points[:, 1])), axis=-1) % 1.0
    uv[state != SURFACE] = 0
    return {'state': state, 'distance': distance, 'position': points, 'material': material,
            'normal': normal, 'uv': uv, 'coverage': (state == SURFACE).astype(float),
            'transmission': transmission}


def water_reference(grid, water_mask):
    """Export the same water rays as the production comparison, with typed metadata."""
    rays = fixture.view_rays()
    directions = rays / np.linalg.norm(rays, axis=-1, keepdims=True)
    indices = np.flatnonzero(water_mask)
    view = directions[indices]
    t = (fixture.WATER_Y - fixture.CAMERA[1]) / view[:, 1]
    origins = fixture.CAMERA + view * t[:, None] + np.array([0.0, 1e-4, 0.0])
    reflected = view * np.array([1.0, -1.0, 1.0])
    result = trace_reference(grid, origins, reflected)
    result['pixel_index'] = indices
    albedo = np.zeros((len(indices), 3))
    radiance = fixture.sky(reflected)
    hit = result['state'] == SURFACE
    if hit.any():
        albedo[hit] = np.array([fixture.ALBEDO.get(int(value), (0, 0, 0)) for value in result['material'][hit]])
        radiance[hit] = fixture.shade(grid, result['position'][hit], result['normal'][hit], result['material'][hit])
    result['albedo'] = albedo
    result['radiance'] = radiance
    return result
