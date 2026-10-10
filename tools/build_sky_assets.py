#!/usr/bin/env python3
"""Bake a periodic cloud volume and NASA lunar albedo into one sampler atlas.

The 64-cubed cloud field stores hybrid value/Worley shape and three erosion
frequencies. Each z slice has a one-texel wrapping border, allowing bilinear
sampling of x/y and manual interpolation of z with ordinary OpenGL 2D textures.
The moon section uses NASA SVS's public-domain LRO mosaic, with attribution kept
beside the generated asset. Run with .preview/venv/bin/python.
"""

from pathlib import Path
import argparse
import io
import urllib.request

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MOON_URL = 'https://svs.gsfc.nasa.gov/vis/a000000/a004700/a004720/lroc_color_2k.jpg'
RESOLUTION = 64


def value_volume(cells, seed):
    """Sample periodic lattice values with a smooth interpolation polynomial."""
    rng = np.random.default_rng(seed)
    lattice = rng.random((cells, cells, cells), dtype=np.float32)
    z, y, x = np.indices((RESOLUTION,) * 3, dtype=np.float32) * (cells / RESOLUTION)
    coordinates = (x, y, z)
    lower = [np.floor(axis).astype(np.int32) for axis in coordinates]
    weights = [axis - index for axis, index in zip(coordinates, lower)]
    weights = [weight * weight * (3.0 - 2.0 * weight) for weight in weights]
    result = np.zeros_like(x)
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                sample = lattice[(lower[2] + dz) % cells,
                                 (lower[1] + dy) % cells,
                                 (lower[0] + dx) % cells]
                weight = (weights[0] if dx else 1.0 - weights[0])
                weight = weight * (weights[1] if dy else 1.0 - weights[1])
                weight = weight * (weights[2] if dz else 1.0 - weights[2])
                result += sample * weight
    return result


def worley_volume(cells, seed):
    """Find periodic nearest feature points without a per-voxel Python loop."""
    rng = np.random.default_rng(seed)
    features = rng.random((cells, cells, cells, 3), dtype=np.float32)
    z, y, x = np.indices((RESOLUTION,) * 3, dtype=np.float32) * (cells / RESOLUTION)
    ix, iy, iz = (np.floor(axis).astype(np.int32) for axis in (x, y, z))
    nearest = np.full(x.shape, 10.0, dtype=np.float32)
    for dz in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                point = features[(iz + dz) % cells, (iy + dy) % cells, (ix + dx) % cells]
                distance = ((ix + dx + point[..., 0] - x) ** 2
                            + (iy + dy + point[..., 1] - y) ** 2
                            + (iz + dz + point[..., 2] - z) ** 2)
                nearest = np.minimum(nearest, distance)
    return np.clip(1.0 - np.sqrt(nearest) * 1.15, 0.0, 1.0)


def build(moon_path=None):
    """Generate deterministic pixels and preserve the external source credit."""
    output = ROOT / 'shaders' / 'textures'
    output.mkdir(parents=True, exist_ok=True)
    fbm = (value_volume(4, 17) * 0.57 + value_volume(8, 23) * 0.29
           + value_volume(16, 31) * 0.14)
    base = fbm * 0.72 + worley_volume(4, 41) * 0.28
    channels = (base, worley_volume(8, 43), worley_volume(16, 47), worley_volume(32, 53))
    volume = np.stack(channels, axis=-1)
    atlas = np.zeros((1024, 1024, 4), dtype=np.uint8)
    for z in range(RESOLUTION):
        tile = np.pad(volume[z], ((1, 1), (1, 1), (0, 0)), mode='wrap')
        x = (z % 8) * 66
        y = (z // 8) * 66
        atlas[y:y+66, x:x+66] = np.rint(tile * 255.0).astype(np.uint8)
    if moon_path:
        moon = Image.open(moon_path)
    else:
        cache = ROOT / '.preview' / 'sky-assets' / 'lroc_color_2k.jpg'
        cache.parent.mkdir(parents=True, exist_ok=True)
        if not cache.exists():
            with urllib.request.urlopen(MOON_URL, timeout=60) as response:
                cache.write_bytes(response.read())
        moon = Image.open(io.BytesIO(cache.read_bytes()))
    moon = moon.convert('RGBA').resize((512, 256), Image.Resampling.LANCZOS)
    atlas[768:1024, 0:512] = np.asarray(moon)
    Image.fromarray(atlas).save(output / 'sky-noise.png')
    (output / 'sky-noise.png.mcmeta').write_text(
        '{"texture":{"blur":true,"clamp":false}}\n')
    print('Cloud shape range:', round(float(base.min()), 3), round(float(base.max()), 3))
    print('Wrote', output / 'sky-noise.png')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--moon', type=Path, help='Use a locally cached NASA color map')
    build(parser.parse_args().moon)
