"""Assemble the stage renderer from production world producers and a plain view.

This isolates collection from lighting and optics. No external scene information
is supplied; generated layouts are shared by GLSL and readback verification.
"""
import json
from pathlib import Path
import shutil
import sys

from .migration_platform import BASE_FRAGMENT, BASE_VERTEX, FULLSCREEN, FINAL

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from migration_layout import build as resource_layout, emit_glsl
from world_metadata import build_fixture


def build(target, preset='LOW', debug=0):
    contract = resource_layout(preset, 1280, 720)
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'shaders/lib/world', target / 'lib/world', dirs_exist_ok=True)
    layout = emit_glsl(contract)
    definitions = []
    for name in ('solar', 'capture_near', 'capture_far'):
        rectangle = contract['capture']['regions'][name]
        suffix = name.removeprefix('capture_').upper()
        definitions.append('const ivec4 WORLD_CAPTURE_' + suffix + ' = ivec4('
                           + ','.join(str(rectangle[key]) for key in ('x','y','width','height')) + ');')
    definitions.append(f'const int WORLD_CAPTURE_SIDE = {contract["capture"]["width"]};')
    (target / 'lib/world/layout.glsl').write_text(layout + '\n#ifndef WORLD_CAPTURE_REGIONS_GLSL\n#define WORLD_CAPTURE_REGIONS_GLSL\n'
        + '\n'.join(definitions) + '\n#endif\n')
    (target / 'world-layout.json').write_text(json.dumps(contract, indent=2) + '\n')
    build_fixture(target, (ROOT / 'shaders/block.properties').read_text())
    width, height = contract['persistent']['width'], contract['persistent']['height']
    (target / 'shaders.properties').write_text(f'''shadow.culling=false
shadowTerrain=true
shadowTranslucent=true
shadowEntities=false
shadowBlockEntities=false
clouds=off
screen=WORLD_DEBUG_VIEW
size.buffer.colortex6={width} {height}
texture.prepare.noisetex.1=textures/world-static.bin TEXTURE_3D RGBA32F 64 64 64 RGBA FLOAT
''')
    base_vertex = BASE_VERTEX
    base_fragment = BASE_FRAGMENT
    for dimension in ('', 'world-1', 'world1'):
        folder = target / dimension
        folder.mkdir(exist_ok=True)
        for suffix in ('vsh', 'gsh', 'fsh'):
            source = (ROOT / 'shaders/program' / f'world_capture.{suffix}.glsl').read_text()
            if suffix == 'fsh':
                source += '\nconst int shadowMapResolution = '+str(contract['capture']['width'])+';\nconst float shadowDistance = 96.0;\n'
            (folder / ('shadow.' + suffix)).write_text('#version 330 core\n' + source)
        for name in ('gbuffers_terrain','gbuffers_water','gbuffers_entities','gbuffers_block',
                     'gbuffers_basic','gbuffers_hand','gbuffers_textured','gbuffers_textured_lit'):
            (folder / (name + '.vsh')).write_text(base_vertex)
            (folder / (name + '.fsh')).write_text(base_fragment)
        (folder / 'prepare.vsh').write_text(FULLSCREEN)
        (folder / 'prepare.fsh').write_text('#version 330 core\n'+
            (ROOT / 'shaders/program/world_resolve.fsh.glsl').read_text())
        (folder / 'deferred.vsh').write_text(FULLSCREEN)
        (folder / 'deferred.fsh').write_text('#version 330 core\n'+
            (ROOT / 'shaders/program/world_surface_probe.fsh.glsl').read_text())
        (folder / 'final.vsh').write_text(FULLSCREEN)
        (folder / 'final.fsh').write_text('#version 330 core\n#define WORLD_DEBUG_VIEW '+str(debug)+' // [0 1 2 3 4]\n'+
            (ROOT / 'shaders/program/world_debug_final.fsh.glsl').read_text())
    return contract


if __name__ == '__main__':
    build(ROOT / 'local-docs/migration/prototypes/P03/shaders')
