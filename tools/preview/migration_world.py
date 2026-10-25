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
from world_catalog import build as build_catalog
from world_assets import Assets, shape_fixture


def build(target, preset='LOW', debug=0, metadata='fixture', packed_uv=True, packed_observation=True):
    packed_uv = packed_uv and metadata == 'vanilla'
    packed_observation = packed_observation and metadata == 'vanilla'
    contract = resource_layout(preset, 1280, 720)
    if packed_observation:
        contract['raw_observation_schema'] = 1
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / 'shaders/lib/world', target / 'lib/world', dirs_exist_ok=True)
    for name in ('foliage_wind.glsl', 'uniforms.glsl', 'common.glsl'):
        shutil.copy2(ROOT / 'shaders/lib' / name, target / 'lib' / name)
    shutil.copy2(ROOT / 'shaders/settings.glsl', target / 'settings.glsl')
    layout = emit_glsl(contract)
    definitions = []
    for name in ('solar', 'capture_near', 'capture_far', 'capture_choices', 'capture_coverage', 'capture_points', 'capture_materials', 'capture_near_faces', 'capture_planar', 'capture_water_planes', 'capture_water_columns', 'capture_environment_ground', 'capture_environment_canopy'):
        rectangle = contract['capture']['regions'][name]
        suffix = name.removeprefix('capture_').upper()
        definitions.append('const ivec4 WORLD_CAPTURE_' + suffix + ' = ivec4('
                           + ','.join(str(rectangle[key]) for key in ('x','y','width','height')) + ');')
    definitions.append(f'const int WORLD_CAPTURE_SIDE = {contract["capture"]["width"]};')
    (target / 'lib/world/layout.glsl').write_text(layout + '\n#ifndef WORLD_CAPTURE_REGIONS_GLSL\n#define WORLD_CAPTURE_REGIONS_GLSL\n'
        + '\n'.join(definitions) + '\n#endif\n')
    (target / 'world-layout.json').write_text(json.dumps(contract, indent=2) + '\n')
    levels = contract['light_levels']
    light_layout = ['#ifndef SIMPLE_WORLD_LIGHT_LAYOUT_GLSL', '#define SIMPLE_WORLD_LIGHT_LAYOUT_GLSL',
        f'const int WORLD_POINT_LIGHT_COUNT = {contract["local_lights"]};',
        f'const int WORLD_GI_SIZE = {contract["gi_size"]};',
        'const float WORLD_POINT_LIGHT_RADIUS = 18.0;',
        f'const int WORLD_POINT_SHADOW_UPDATES = {contract["point_shadow_updates"]};',
        f'#define WORLD_POINT_SHADOW_INVOCATIONS {contract["point_shadow_invocations"]}',
        f'#define WORLD_CAPTURE_INVOCATIONS {contract["point_shadow_invocations"]+1}',
        f'const int WORLD_POINT_SHADOW_SIDE = {contract["point_shadow_side"]};',
        f'const int WORLD_LIGHT_TREE_LEVELS = {len(levels)};',
        'int worldLightLevelCount(int level) {']
    for index,item in enumerate(levels,1):
        light_layout.append(f'    if (level == {index}) return {item["count"]};')
    light_layout += ['    return 0;', '}', 'int worldLightLevelOffset(int level) {']
    for index,item in enumerate(levels,1):
        light_layout.append(f'    if (level == {index}) return {item["offset"]};')
    light_layout += ['    return 0;', '}', 'int worldLightLeafSpan(int level) {']
    for index in range(len(levels)+1):
        light_layout.append(f'    if (level == {index}) return {4**index};')
    light_layout += ['    return 1;', '}', '#endif', '']
    (target/'lib/world/light_layout.glsl').write_text('\n'.join(light_layout))

    if metadata == 'vanilla':
        catalog = build_catalog(target)
        (target/'lib/world/dynamic_layout.glsl').write_text(
            '#ifndef SIMPLE_WORLD_DYNAMIC_LAYOUT_GLSL\n#define SIMPLE_WORLD_DYNAMIC_LAYOUT_GLSL\n'
            f'const int WORLD_CONDUIT_MATERIAL = {catalog["defaults"]["minecraft:conduit"]};\n'
            '#endif\n')
        definitions = json.loads((ROOT/'local-docs/migration/registry/runtime-v2/vanilla-blocks.json').read_text())
        defaults = {block['name']:block['defaults'] for block in definitions['blocks']}
        lookup = {(state['block'],json.dumps(state['properties'],sort_keys=True)):state for state in catalog['states']}
        fixture = shape_fixture(Assets())
        for index,item in enumerate(fixture):
            name = 'minecraft:'+item['block']
            properties = {**defaults[name],**item['properties']}
            state = lookup[(name,json.dumps(properties,sort_keys=True))]
            item.update(material=state['id'],first_box=state['first_box'],box_count=state['box_count'],
                        position=[2800+(index%14)*2,201,2800+(index//14)*2])
        by_name = {block['name']:block for block in definitions['blocks']}
        requested = ('minecraft:torch','minecraft:soul_torch','minecraft:redstone_lamp',
                     'minecraft:red_stained_glass','minecraft:blue_stained_glass',
                     'minecraft:grass_block','minecraft:short_grass','minecraft:bamboo',
                     'minecraft:pointed_dripstone','minecraft:chorus_plant',
                     'minecraft:pink_petals','minecraft:wildflowers')
        extras = []
        for name in requested:
            props = defaults[name]
            extras.append(lookup[(name,json.dumps(props,sort_keys=True))])
        highest = max((state for state in catalog['states'] if state['render_shape']=='MODEL'
                       and state['flags'] & 256 and not state['flags'] & (16|2048)),key=lambda state:state['id'])
        extras.append(highest)
        assets = Assets()
        for state in extras:
            index = len(fixture)
            fixture.append({'block':state['block'].split(':')[1],
                'properties':state['properties'],
                'boxes':[(part[:3],part[3:6]) for part in assets.oriented_parts(state['block'],state['properties'])],
                'material':state['id'],'first_box':state['first_box'],'box_count':state['box_count'],
                'position':[2800+(index%14)*2,201,2800+(index//14)*2]})
        (target/'world-fixture.json').write_text(json.dumps({'schema_version':2,'states':fixture,'state_stride':3,'shape_stride':3},indent=2)+'\n')
    else:
        build_fixture(target, (ROOT / 'shaders/block.properties').read_text())
        (target/'lib/world/dynamic_layout.glsl').write_text(
            '#ifndef SIMPLE_WORLD_DYNAMIC_LAYOUT_GLSL\n#define SIMPLE_WORLD_DYNAMIC_LAYOUT_GLSL\n'
            'const int WORLD_CONDUIT_MATERIAL = 0;\n#endif\n')
    width, height = contract['persistent']['width'], contract['persistent']['height']
    (target / 'shaders.properties').write_text(f'''shadow.culling=false
oldLighting=false
separateAo=true
shadowTerrain=true
shadowTranslucent=true
shadowEntities=false
shadowBlockEntities=true
clouds=off
screen=WORLD_DEBUG_VIEW
size.buffer.colortex6={width} {height}
texture.noise=textures/world-static.bin TEXTURE_2D RGBA32F {contract["static_size"][0]} {contract["static_size"][1]} RGBA FLOAT
''')
    if metadata == 'vanilla':
        with (target/'shaders.properties').open('a') as properties:
            # J9 initializes shadow colortex4..7 sampler units only when the
            # gbuffer custom-texture array exists. Initialize the ordinary diffuse
            # unit with the live atlas; native draw calls still bind their skins.
            properties.write('texture.gbuffers.texture=minecraft:textures/atlas/blocks.png\n'
                             'texture.prepare.depthtex2=minecraft:textures/atlas/blocks.png\n'
                             'texture.deferred.depthtex2=minecraft:textures/atlas/blocks.png\n')
            properties.write('texture.prepare.colortex0=minecraft:textures/block/stone.png\n'
                             'texture.prepare.colortex1=minecraft:textures/block/deepslate.png\n'
                             'texture.prepare.colortex2=minecraft:textures/block/netherrack.png\n'
                             'texture.prepare.colortex3=minecraft:textures/entity/conduit/base.png\n'
                             'texture.prepare.colortex4=minecraft:textures/entity/conduit/cage.png\n')
    if packed_observation:
        with (target/'shaders.properties').open('a') as properties:
            properties.write('blend.shadow=ONE ONE\nblend.shadow.shadowcolor0=ONE ONE\nblend.shadow.shadowcolor1=off\n')
    base_vertex = BASE_VERTEX
    base_fragment = BASE_FRAGMENT
    if metadata == 'vanilla':
        base_vertex = base_vertex.replace('in vec2 vaUV0;',
            'in vec2 vaUV0;\nin vec3 vaNormal;\nuniform mat3 normalMatrix;\n'
            'uniform mat4 gbufferModelViewInverse;\nout vec3 referenceNormal;')
        base_vertex = base_vertex.replace('uv = vaUV0;',
            'uv = vaUV0;\n    referenceNormal = mat3(gbufferModelViewInverse) * normalMatrix * vaNormal;')
        # Independent raster UVs are read back for verification only. They do
        # not participate in the shadow collector or world UV publication.
        base_fragment = base_fragment.replace('RENDERTARGETS: 0', 'RENDERTARGETS: 0,2')
        base_fragment = base_fragment.replace('uniform sampler2D gtexture;',
            '/*\nconst int colortex2Format = RGBA32F;\n*/\n'
            '#include "/lib/world/atlas_uv.glsl"\n'
            '#include "/lib/world/uv.glsl"\nin vec3 referenceNormal;\n'
            'uniform vec4 spriteBounds;\n'
            'uniform ivec2 atlasSize;\nuniform int blockEntityId;\n'
            'layout(location=1) out vec4 referenceUv;\nuniform sampler2D gtexture;')
        base_fragment = base_fragment.replace('outColor0 = vec4(albedo.rgb * colour.rgb, 1.0);',
            'outColor0 = vec4(albedo.rgb * colour.rgb, 1.0);\n'
            '    int axis = worldSurfaceAxis(referenceNormal);\n'
            '    referenceUv = vec4(worldAtlasUv(uv, spriteBounds, textureSize(gtexture, 0), atlasSize),\n'
            '        float(axis * 2 + int(referenceNormal[axis] < 0.0)), blockEntityId > 0 ? 2.0 : 1.0);')
    for dimension in ('', 'world-1', 'world1'):
        folder = target / dimension
        folder.mkdir(exist_ok=True)
        for suffix in ('vsh', 'gsh', 'fsh'):
            source = (ROOT / 'shaders/program' / f'world_capture.{suffix}.glsl').read_text()
            if suffix == 'fsh':
                source += '\nconst int shadowMapResolution = '+str(contract['capture']['width'])+';\nconst float shadowDistance = 96.0;\n'
            (folder / ('shadow.' + suffix)).write_text(('#version 400 core\n' if suffix == 'gsh' else '#version 330 core\n')
                + ('#define WORLD_SHADOW_DIAGNOSTIC (1)\n' if debug == 8 else '')
                + ('#define WORLD_MODEL_UV (1)\n' if metadata == 'vanilla' else '')
                + ('#define WORLD_PACKED_OBSERVATION (1)\n' if packed_observation else '')
                + ('#define WORLD_PACKED_UV (1)\n' if packed_uv else '') + source)
        for name in ('gbuffers_terrain','gbuffers_water','gbuffers_entities','gbuffers_block',
                     'gbuffers_basic','gbuffers_hand','gbuffers_textured','gbuffers_textured_lit'):
            (folder / (name + '.vsh')).write_text(base_vertex)
            (folder / (name + '.fsh')).write_text(base_fragment)
        (folder / 'prepare.vsh').write_text(FULLSCREEN)
        (folder / 'prepare.fsh').write_text('#version 330 core\n'+
            ('#define WORLD_ATLAS_PROBE (1)\n' if metadata == 'vanilla' else '')+
            ('#define WORLD_PACKED_OBSERVATION (1)\n' if packed_observation else '')+
            ('#define WORLD_PACKED_UV (1)\n' if packed_uv else '')+
            (ROOT / 'shaders/program/world_resolve.fsh.glsl').read_text())
        # Synchronize the world once, then rasterize only each changed region.
        # Paired producers, or a following local copy, keep both banks current.
        (folder/'prepare1.vsh').write_text(FULLSCREEN)
        (folder/'prepare1.fsh').write_text('#version 330 core\n'
            +(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())
        pass_index = 2
        tree = contract['persistent']['regions']['light_hierarchy']
        optics = contract['persistent']['regions']['far_optics']
        rectangle = [optics[key] for key in ('x','y','width','height')]
        changes = contract['persistent']['regions']['far_coverage']
        changed_rectangle = [changes[key] for key in ('x','y','width','height')]
        draws = [(changed_rectangle,(ROOT/'shaders/program/world_geometry_changes.fsh.glsl').read_text()),
                 (changed_rectangle,(ROOT/'shaders/program/world_copy.fsh.glsl').read_text()),
                 (rectangle,(ROOT/'shaders/program/world_air.fsh.glsl').read_text()),
                 (rectangle,(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())]
        ray = contract['persistent']['regions']['ray_coverage']
        ray_rectangle = [ray[key] for key in ('x','y','width','height')]
        draws += [(ray_rectangle,(ROOT/'shaders/program/world_ray_coverage.fsh.glsl').read_text()),
                  (ray_rectangle,(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())]
        for level,item in enumerate(levels,1):
            rows = (item['count']+tree['width']-1)//tree['width']
            rectangle = [tree['x'],tree['y']+item['offset']//tree['width'],tree['width'],rows]
            source = '#define WORLD_LIGHT_BUILD_LEVEL '+str(level)+'\n'
            source += 'const ivec4 WORLD_LIGHT_DRAW_RECT = ivec4('+','.join(map(str,rectangle))+');\n'
            source += (ROOT/'shaders/program/world_light_tree.fsh.glsl').read_text()
            draws.extend([(rectangle,source)]*2)
        ranked = contract['persistent']['regions']['light_ranked']
        rectangle = [ranked['x'],ranked['y'],contract['local_lights'],1]
        rank_source = (ROOT/'shaders/program/world_light_rank.fsh.glsl').read_text()
        draws.extend([(rectangle,rank_source)]*2)
        matching = contract['persistent']['regions']['light_matching']
        rectangle = [matching['x'],matching['y'],contract['local_lights'],1]
        match_source = (ROOT/'shaders/program/world_light_match.fsh.glsl').read_text()
        draws.extend([(rectangle,match_source)]*2)
        selection = contract['persistent']['regions']['light_selection']
        records = 8+contract['local_lights']*4
        rectangle = [selection['x'],selection['y'],selection['width'],(records+selection['width']-1)//selection['width']]
        draws.extend([(rectangle,(ROOT/'shaders/program/world_light_publish.fsh.glsl').read_text())]*2)
        rectangle = [selection['x']+6,selection['y'],2,1]
        draws.extend([(rectangle,(ROOT/'shaders/program/world_light_schedule.fsh.glsl').read_text())]*2)
        transfer = contract['persistent']['regions']['glass_transfer']
        rectangle = [transfer[key] for key in ('x','y','width','height')]
        draws += [(rectangle,(ROOT/'shaders/program/world_glass_transfer.fsh.glsl').read_text()),
                  (rectangle,(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())]


        hue = contract['persistent']['regions']['hue']
        rectangle = [hue[key] for key in ('x','y','width','height')]
        draws += [(rectangle,(ROOT/'shaders/program/world_hue.fsh.glsl').read_text()),
                  (rectangle,(ROOT/'shaders/program/world_hue.fsh.glsl').read_text()),
                  (rectangle,(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())]
        gi_header = contract['persistent']['regions']['gi_control']
        rectangle = [gi_header[key] for key in ('x','y','width','height')]
        draws += [(rectangle,(ROOT/'shaders/program/world_gi_begin.fsh.glsl').read_text()),
                  (rectangle,(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())]
        gi_storage = contract['persistent']['regions']['gi_storage']
        rectangle = [gi_storage[key] for key in ('x','y','width','height')]
        for substep in range(8):
            draws.append((rectangle,'#define WORLD_GI_SUBSTEP '+str(substep)+'\n'
                +(ROOT/'shaders/program/world_gi_step.fsh.glsl').read_text()))
        for region,program in (('ground_columns','world_ground_columns'),
                               ('environment_columns','world_environment_columns'),
                               ('environment_columns','world_environment_filter'),
                               ('water_columns','world_water_columns'),
                               ('water_column_control','world_water_column_control'),
                               ('water_medium','world_water_medium'),
                               ('ore_pending','world_ore_prepare'),
                               ('ore_masks','world_ore_masks'),
                               ('ore_metadata','world_ore_publish'),
                               ('dynamic_sprites','world_dynamic_sprites')):
            area = contract['persistent']['regions'][region]
            rectangle = [area[key] for key in ('x','y','width','height')]
            draws += [(rectangle,(ROOT/'shaders/program'/(program+'.fsh.glsl')).read_text()),
                      (rectangle,(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())]
        for rectangle,source in draws:
            # Clip the native fullscreen quad to the atlas subrectangle before
            # rasterization; fragments outside it never execute.
            vertex = FULLSCREEN
            body = 'vec2 lo = vec2('+str(rectangle[0])+'.0,'+str(rectangle[1])+'.0);\n'
            body += '    vec2 span = vec2('+str(rectangle[2])+'.0,'+str(rectangle[3])+'.0);\n'
            body += '    vec2 corner = gl_Position.xy * 0.5 + 0.5;\n'
            body += '    gl_Position.xy = (lo + corner * span) / vec2('+str(width)+'.0,'+str(height)+'.0) * 2.0 - 1.0;\n'
            last = vertex.rfind('}')
            vertex = vertex[:last]+'    '+body+vertex[last:]
            (folder/('prepare'+str(pass_index)+'.vsh')).write_text(vertex)
            (folder/('prepare'+str(pass_index)+'.fsh')).write_text('#version 330 core\n'+source)
            pass_index += 1
        (folder / 'deferred.vsh').write_text(FULLSCREEN)
        (folder / 'deferred.fsh').write_text('#version 330 core\n'+
            ('#define WORLD_UV_PROBE (1)\n#define WORLD_MODEL_UV (1)\n' if metadata == 'vanilla' else '')+
            (ROOT / 'shaders/program/world_surface_probe.fsh.glsl').read_text())
        (folder / 'final.vsh').write_text(FULLSCREEN)
        (folder / 'final.fsh').write_text('#version 330 core\n#define WORLD_DEBUG_VIEW '+str(debug)+' // [0 1 2 3 4 5 6 8 10]\n'+
            (ROOT / 'shaders/program/world_debug_final.fsh.glsl').read_text())
    return contract


if __name__ == '__main__':
    build(ROOT / 'local-docs/migration/prototypes/P03/shaders')
