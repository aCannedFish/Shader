#!/usr/bin/env python3
"""Analytic first-hit, alpha-hole and glass tests for the independent CPU oracle."""
import json
from pathlib import Path
import numpy as np
import check_reflection_scene as fixture
from preview.migration_reference import SKY, SURFACE, trace_reference

ROOT = Path(__file__).resolve().parents[1]


def main():
    grid = np.zeros(fixture.SIZE, np.uint8)
    def put(x, y, z, material):
        grid[x - fixture.LOW[0], y - fixture.LOW[1], z - fixture.LOW[2]] = material
    put(0, 80, -10, fixture.LEAVES)
    put(0, 80, -12, fixture.GROUND)
    y, x = np.mgrid[:16, :16]
    opaque = fixture.leaf_opaque((x + .5) / 16, (y + .5) / 16)
    hole_y, hole_x = np.argwhere(~opaque)[0]
    leaf_y, leaf_x = np.argwhere(opaque)[0]
    starts = np.array([[(hole_x + .5) / 16, 80 + (hole_y + .5) / 16, .5],
                       [(leaf_x + .5) / 16, 80 + (leaf_y + .5) / 16, .5]])
    rays = np.array([[0, 0, -1], [0, 0, -1]], float)
    hit = trace_reference(grid, starts, rays)
    assert np.array_equal(hit['state'], [SURFACE, SURFACE])
    assert np.array_equal(hit['material'], [fixture.GROUND, fixture.LEAVES])
    assert np.allclose(hit['distance'], [11.5, 9.5])
    assert np.allclose(hit['normal'], [[0, 0, 1], [0, 0, 1]])
    assert np.allclose(hit['uv'], [[(hole_x+.5)/16, (hole_y+.5)/16], [(leaf_x+.5)/16, (leaf_y+.5)/16]])
    put(0, 80, -12, fixture.AIR)
    assert trace_reference(grid, starts[:1], rays[:1])['state'][0] == SKY
    # Two one-block glass layers leave the first solid hit unchanged and multiply RGB transfer.
    grid.fill(0)
    glass = 6
    put(0, 80, -4, glass)
    put(0, 80, -6, glass)
    put(0, 80, -10, fixture.TRUNK)
    sigma = np.array([.2, .4, .8])
    layered = trace_reference(grid, np.array([[.5,80.5,.5]]), rays[:1], glass, sigma)
    assert layered['material'][0] == fixture.TRUNK
    assert abs(layered['distance'][0] - 9.5) < 1e-4
    assert np.allclose(layered['transmission'][0], np.exp(-sigma * 2), atol=2e-5)
    output = ROOT / 'local-docs/migration/reference-verification.json'
    output.write_text(json.dumps({'analytic_distance_normal_uv': True, 'leaf_hole_reaches_background': True,
                                  'opaque_leaf_stops_ray': True, 'leaf_hole_reaches_sky': True,
                                  'layered_glass_rgb_absorption': True}, indent=2)+'\n')
    print(output.read_text())


if __name__ == '__main__':
    main()
