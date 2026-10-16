"""Check render-quality resizing with real client frames and GPU UV readbacks."""

import json
import math

from PIL import Image


AIR = ('100', '050', '067', '075', '117', '150', '200', 'reset')
WATER = ('050', '200')


def pillar_bounds(image, blue):
    """Measure stable coloured geometry above the animated water foreground."""
    width, height = image.size
    left, right = (0.55, 0.73) if blue else (0.30, 0.46)
    region = (int(width * left), 0, int(width * right), int(height * 0.60))
    patch = image.crop(region)
    points = []
    for index, (r, g, b) in enumerate(patch.get_flattened_data()):
        selected = b > r * 2 + 10 and b > g * 2 + 10 if blue else (
            r > g * 2 + 10 and r > b * 1.5 + 10)
        if selected:
            points.append((index % patch.width + region[0], index // patch.width))
    if not points:
        raise RuntimeError('A reference pillar disappeared from the output viewport')
    return (min(x for x, y in points), min(y for x, y in points),
            max(x for x, y in points), max(y for x, y in points))


def verify_scale(root, check_uv=False):
    """Require complete framing, actual buffer resizing and optional normalized UVs."""
    work = root / '.preview/render-scale-review'
    directory = work / 'native'
    if not directory.exists():
        raise RuntimeError('Render-quality captures are missing; capture the scale_air/scale_water fixtures first')
    reference = Image.open(directory / 'scale_air_100.png').convert('RGB')
    expected = [pillar_bounds(reference, blue) for blue in (False, True)]
    result = {}
    names = ['scale_air_' + suffix for suffix in AIR]
    names += ['scale_water_' + suffix for suffix in WATER]
    for name in names:
        image = Image.open(directory / (name + '.png')).convert('RGB')
        metadata = json.loads((directory / (name + '-scale.json')).read_text())
        output = (metadata['output_width'], metadata['output_height'])
        if image.size != output or output != reference.size:
            raise RuntimeError('Render quality unexpectedly resized the output window: ' + name)
        for axis in ('width', 'height'):
            rounded = math.floor(metadata['output_' + axis] * metadata['scale'] + 0.5)
            if abs(metadata['internal_' + axis] - rounded) > 1:
                raise RuntimeError('The client did not apply the requested render quality: ' + name)
        entry = dict(metadata)
        if name.startswith('scale_air_'):
            actual = [pillar_bounds(image, blue) for blue in (False, True)]
            error = max(abs(a - b) for first, second in zip(expected, actual)
                        for a, b in zip(first, second))
            if error > 3:
                raise RuntimeError('Geometry shifts with render quality: ' + name)
            entry['pillar_edge_error_pixels'] = error
        if check_uv:
            probe = Image.open(work / 'uv' / (name + '.png')).convert('RGB')
            if probe.size != output:
                raise RuntimeError('UV probe output size differs: ' + name)
            errors = []
            for u in (0.02, 0.25, 0.50, 0.75, 0.98):
                for v in (0.02, 0.25, 0.50, 0.75, 0.98):
                    x, y = int(u * probe.width), int(v * probe.height)
                    expected_pixel = (255 * (x + 0.5) / probe.width,
                                      255 * (1.0 - (y + 0.5) / probe.height), 0.0)
                    errors.extend(abs(a - b) for a, b in zip(probe.getpixel((x, y)), expected_pixel))
            if max(errors) > 1.0:
                raise RuntimeError('Final UV does not span the output viewport: ' + name)
            entry['uv_max_channel_error'] = max(errors)
        result[name] = entry
    (work / 'verification.json').write_text(json.dumps(result, indent=2))
    return result
