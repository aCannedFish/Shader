"""Measure the actual project's sky/cloud GLSL in a small offscreen CGL harness."""

import json
import re
import subprocess

from PIL import Image

from .source import expand


def benchmark_sky(root):
    """Time warm GPU draws at the real default lookup/cloud viewport sizes."""
    work = root / '.preview' / 'sky-performance'
    work.mkdir(parents=True, exist_ok=True)
    atlas = work / 'atlas.rgba'
    atlas.write_bytes(Image.open(root/'shaders/textures/sky-noise.png').convert('RGBA').tobytes())
    files = []
    for name, entry, quality in (
        ('atmosphere', 'deferred.fsh', 1),
        ('low', 'composite.fsh', 0),
        ('balanced', 'composite.fsh', 1),
        ('high', 'composite.fsh', 2),
    ):
        source = expand(root/'shaders'/entry, root/'shaders')
        source = source.replace('#version 120', '#version 330 core\nout vec4 probeColor;', 1)
        source = source.replace('gl_FragData[0]', 'probeColor').replace('texture2D(', 'texture(')
        source = re.sub(r'(^#define CLOUD_QUALITY )\d+', r'\g<1>'+str(quality), source, flags=re.MULTILINE)
        file = work / (name+'.fsh')
        file.write_text(source)
        files.append(file)
    binary = work/'sky_probe'
    subprocess.run(['clang', '-Wno-deprecated-declarations', str(root/'tools/preview/sky_probe.m'),
                    '-framework', 'OpenGL', '-o', str(binary)], check=True)
    result = subprocess.check_output([str(binary), str(atlas), *map(str, files)], text=True)
    parsed = json.loads(result)
    (work/'timing.json').write_text(json.dumps(parsed, indent=2))
    print(json.dumps(parsed, indent=2), flush=True)
    return parsed
