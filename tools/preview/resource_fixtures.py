"""Deterministic resource inputs for native texture-reload validation.

These ordinary PNGs enter Minecraft through its resource-pack loader. The
capture helper never supplies palette pixels or masks directly to a shader.
"""
import argparse
from io import BytesIO
import json
from pathlib import Path
import zipfile

from PIL import Image


def ore_resource64(path):
    """Exercise the supported 64-pixel boundary with an obvious mineral pattern."""
    stone = Image.new('RGBA', (64, 64))
    ore = Image.new('RGBA', (64, 64))
    for y in range(64):
        for x in range(64):
            grey = 88 if (x // 4 + y // 4) % 2 == 0 else 132
            host = (grey, grey, grey, 255)
            mineral = (x % 16 - 8) ** 2 + (y % 16 - 8) ** 2 < 20
            stone.putpixel((x, y), host)
            ore.putpixel((x, y), (210, 40, 160, 255) if mineral else host)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('pack.mcmeta', json.dumps({'pack': {
            'description': 'Migration mineral-mask resource fixture',
            'min_format': [75, 0], 'max_format': [75, 0],
        }}))
        for name, image in (('stone', stone), ('diamond_ore', ore)):
            encoded = BytesIO()
            image.save(encoded, format='PNG')
            archive.writestr('assets/minecraft/textures/block/'+name+'.png', encoded.getvalue())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    ore_resource64(parser.parse_args().path)
