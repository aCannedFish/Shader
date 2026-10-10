"""GPU regressions for silhouette leakage and bounded celestial discs."""

import json
from pathlib import Path
import shutil

from PIL import Image, ImageChops, ImageStat

from .replay import render


BODY_RETURN = 'return skyAtmosphereRadiance(direction) + skyStars(direction) + skyCelestialRadiance(direction);'
NO_BODY_RETURN = 'return skyAtmosphereRadiance(direction) + skyStars(direction);'


def verify_sky(root, runtime, converter, baseline=None):
    """Require celestial-free frames to stay unchanged and actual discs to remain visible."""
    work = root / '.preview/sky-verification'
    work.mkdir(parents=True, exist_ok=True)
    scenes = ('rim_sunset_late', 'rim_night', 'rim_sunrise_early')
    if baseline is None:
        baseline = work / 'baseline'
        render(root, runtime, converter, names=scenes, output=baseline)

    def variant(name, edits, selected):
        shaders = work / (name + '-shaders')
        shutil.copytree(root / 'shaders', shaders, dirs_exist_ok=True)
        for filename, before, after in edits:
            path = shaders / filename
            text = path.read_text()
            if before not in text:
                raise RuntimeError(f'Sky verification edit no longer applies: {filename}')
            path.write_text(text.replace(before, after, 1))
        output = work / name
        render(root, runtime, converter, names=selected, shader_root=shaders, output=output)
        return output

    no_bodies = variant('no-bodies', [('lib/sky.glsl', BODY_RETURN, NO_BODY_RETURN)], scenes)
    residuals = {}
    for name in scenes:
        original = Image.open(baseline / (name + '.png')).convert('RGB')
        reference = Image.open(no_bodies / (name + '.png')).convert('RGB')
        residuals[name] = sum(ImageStat.Stat(ImageChops.difference(original, reference)).mean) / 3.0
        # Neither disc intersects these views. Turning them off must not remove a contour.
        if residuals[name] > 0.01:
            raise RuntimeError(f'Celestial colour leaks outside its disc: {name}={residuals[name]}')

    probes = {}
    for body in ('sun', 'moon'):
        # Move the body only inside the sky query; keep geometry lighting and
        # its captured uniform set unchanged during the synthetic visibility test.
        edits = [('settings.glsl', '#define ENABLE_BLOOM 1', '#define ENABLE_BLOOM 0')]
        if body == 'sun':
            edits.append(('lib/sky.glsl', 'vec3 sun = skySunDirection();',
                          'vec3 sun = skyViewDirection(vec2(0.75, 0.75));'))
        if body == 'moon':
            edits.append(('lib/sky.glsl', 'return solar + lunarDisc(ray, skyMoonDirection());',
                          'return lunarDisc(ray, skyViewDirection(vec2(0.75, 0.75)));'))
        visible = variant(body, edits, ('rim_sunset_late',))
        hidden = variant(body + '-hidden', [*edits, ('lib/sky.glsl', BODY_RETURN, NO_BODY_RETURN)],
                         ('rim_sunset_late',))
        a = Image.open(visible / 'rim_sunset_late.png').convert('RGB')
        b = Image.open(hidden / 'rim_sunset_late.png').convert('RGB')
        difference = ImageChops.difference(a, b)
        changed = sum(max(pixel) > 8 for pixel in difference.getdata())
        box = difference.point(lambda channel: 255 if channel > 8 else 0).getbbox()
        if box is None or changed < 500:
            raise RuntimeError(f'The {body} disc is no longer visible')
        width, height = box[2] - box[0], box[3] - box[1]
        if width > 200 or height > 200:
            raise RuntimeError(f'The {body} disc AA is unbounded: {box}')
        probes[body] = {'visible_pixels': changed, 'bounds': list(box)}

    result = {'off_disc_mean_error': residuals, 'celestial_probes': probes}
    (work / 'verification.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), flush=True)
    return result
