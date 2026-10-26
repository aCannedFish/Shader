"""Assemble the complete renderer with GPU world-lighting producers.

The result is an isolated OptiFine pack. Existing surface/sky/water/post modules
remain the visual front end; their companion API resolves to GPU atlas data.
The reference checkout and installed release are never overwritten.
"""
import argparse
import json
from pathlib import Path
import re
import shutil

from .migration_world import ROOT, build as build_world


VERTEX_INPUTS = '''
in vec3 vaPosition;
in vec4 vaColor;
in vec3 vaNormal;
in vec2 vaUV0;
in ivec2 vaUV2;
uniform vec3 modelOffset;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat3 normalMatrix;
'''



def vertex_symbols(source):
    """Expand legacy expressions before J9's compatibility rewriter sees them."""
    replacements = {
        'ftransform()':'(projectionMatrix * modelViewMatrix * vec4(vaPosition + modelOffset, 1.0))',
        'gl_ModelViewProjectionMatrix':'(projectionMatrix * modelViewMatrix)',
        'gl_ModelViewMatrix':'modelViewMatrix',
        'gl_ProjectionMatrix':'projectionMatrix',
        'gl_NormalMatrix':'normalMatrix',
        'gl_MultiTexCoord0':'vec4(vaUV0, 0.0, 1.0)',
        'gl_MultiTexCoord1':'vec4(vec2(vaUV2), 0.0, 1.0)',
        'gl_Vertex':'vec4(vaPosition + modelOffset, 1.0)',
        'gl_Normal':'vaNormal',
        'gl_Color':'vaColor',
    }
    for previous, replacement in replacements.items():
        source = source.replace(previous, replacement)
    return source


def modernize(source, stage, world_entity=True):
    """Use J9's native attributes and explicit fragment outputs."""
    source = re.sub(r'^#version[^\n]*\n', '', source, flags=re.M)
    source = source.replace('(gl_TextureMatrix[0] * gl_MultiTexCoord0).xy', 'vaUV0')
    source = source.replace('(gl_TextureMatrix[1] * gl_MultiTexCoord1).xy',
                            '((vec2(vaUV2) + 8.0) / 256.0)')
    source = re.sub(r'\battribute\b', 'in', source)
    source = re.sub(r'\btexture\b', 'gtexture', source)
    source = source.replace('texture2DLod(', 'textureLod(').replace('texture2D(', 'texture(')
    if stage == 'vsh':
        source = re.sub(r'in vec2 mc_Entity;', '', source)
        source = vertex_symbols(source)
        source = re.sub(r'\bvarying\b', 'SIMPLE_VARYING', source)
        prefix = '#define SIMPLE_VARYING out\n' + VERTEX_INPUTS
        if 'mc_Entity' in source and not world_entity:
            source = re.sub(r'\bmc_Entity\b', 'legacyEntity', source)
            source = source.replace('void main() {', '''void main() {
    float alias = mc_Entity.x;
    if (alias >= 6000.0 && alias <= 6007.0) {
        alias = alias == 6000.0 || alias == 6003.0 ? 101.0 : 102.0;
    }
    vec2 legacyEntity = vec2(alias, mc_Entity.y);''')
            prefix += 'in vec3 mc_Entity;\n'
        if 'mc_Entity' in source and world_entity:
            source = re.sub(r'\bmc_Entity\b', 'legacyEntity', source)
            source = source.replace('void main() {', 'void main() {\n    vec2 legacyEntity = worldLegacyEntity();')
            prefix += '''
#include "/lib/world/storage.glsl"
in vec3 mc_Entity;
vec2 worldLegacyEntity() {
    int alias = clamp(int(round(mc_Entity.x)), 0, 32767);
    int index = alias * 3;
    int width = textureSize(noisetex, 0).x;
    float legacy = texelFetch(noisetex, ivec2(index % width, index / width), 0).w;
    return vec2(legacy, mc_Entity.y);
}
'''
        return prefix + source
    last_output = max([4] + [int(value) for value in re.findall(r'gl_FragData\[(\d)\]', source)])
    outputs = '' if 'layout(location=' in source else ''.join(
        f'layout(location={index}) out vec4 fullOut{index};\n' for index in range(last_output + 1))
    source = re.sub(r'gl_FragData\[(\d)\]', r'fullOut\1', source)
    source = re.sub(r'\bvarying\b', 'SIMPLE_VARYING', source)
    return '#define SIMPLE_VARYING in\n' + outputs + source


def replace_texture_calls(source):
    """Route legacy logical solar reads into the physical capture partition."""
    source = source.replace('shadowcolor0', 'shadowcolor1')
    for sampler in ('shadowtex0', 'shadowtex1', 'depthMap'):
        pattern = r'texture2D\(' + sampler + r',\s*([^;\n]*?)\)\.r'
        # Only these consumers pass simple or balanced UV expressions. A small
        # balanced scan also handles shadowTexelCenter(coordinate.xy).
        start = 'texture2D(' + sampler + ','
        while start in source:
            first = source.index(start)
            value_start = first + len(start)
            cursor, depth = value_start, 1
            while depth:
                depth += (source[cursor] == '(') - (source[cursor] == ')')
                cursor += 1
            if source[cursor:cursor+2] != '.r':
                raise ValueError('Solar depth read must select its red channel')
            argument = source[value_start:cursor-1].strip()
            source = source[:first] + f'worldSolarDepth({sampler}, {argument})' + source[cursor+2:]
    source = re.sub(r'texture2D\(shadowcolor1,\s*([^)]*)\)',
                    r'worldSolarColour(shadowcolor1, \1)', source)
    return source



def inline_shader(path, root, seen=None):
    """Package flat entry points within J9's ten-level include limit."""
    seen = set() if seen is None else seen
    path = path.resolve()
    if path in seen:
        return ''
    seen.add(path)
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'\s*#include\s+"([^"]+)"', line)
        if match:
            include = match.group(1)
            dependency = root/include.lstrip('/') if include.startswith('/') else path.parent/include
            lines.append(inline_shader(dependency, root, seen))
        else:
            lines.append(line)
    return '\n'.join(lines)+'\n'


def mark_native_stage(source, fragment=False):
    """Tell J9 that this generated stage has already been modernized.

    J9 recognizes its compatibility header and returns native GLSL unchanged.
    The Windows render-thread dump showed repeated remapping of large fragment
    programs during hangs. Keep legacy fullscreen vertex stages on J9's normal
    path, and reject legacy syntax here before using the native-stage header.
    """
    code = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    legacy = (r'\b(?:attribute|varying|texture2D|shadow2D)\b|'
              r'\bgl_(?:FragData|FragColor|Vertex|Color|Normal|MultiTexCoord\d|'
              r'ModelViewMatrix|ProjectionMatrix|TextureMatrix)\b')
    if re.search(legacy, code):
        raise ValueError('Generated native stage still contains legacy GLSL')
    first = source.index('\n') + 1
    header = '// Compatibility (auto-generated)\n'
    if fragment:
        # The exact RTX 4060 input linked composite2 in 62.5 seconds. Limiting
        # native function expansion reduced it to about 13 seconds without
        # changing its statements or sampling budgets. Keep other vendors on
        # their normal compiler path; this is not an effect-quality switch.
        header += ('#ifdef MC_GL_VENDOR_NVIDIA\n'
                   '#pragma optionNV(inline 16)\n'
                   '#pragma optionNV(unroll none)\n'
                   '#endif\n')
    return source[:first] + header + source[first:]


def build(target, preset='LOW', world_reflections=False, planar_reflections=False):
    target = Path(target)
    for dimension in ('', 'world-1', 'world1'):
        for pattern in ('prepare*.?sh', 'deferred*.?sh', 'composite*.?sh'):
            for path in (target/dimension).glob(pattern):
                path.unlink()
    contract = build_world(target, preset=preset, metadata='vanilla')
    generated_properties = (target/'shaders.properties').read_text()
    # Preserve generated collection/prepare programs while installing the real
    # scene renderer and resources around them.
    for name in ('lib', 'program', 'textures', 'lang'):
        shutil.copytree(ROOT/'shaders'/name, target/name, dirs_exist_ok=True)
    shutil.copy2(ROOT/'shaders/settings.glsl', target/'settings.glsl')
    settings = (target/'settings.glsl').read_text().replace('const bool colortex6Clear = true;',
                                                         'const bool colortex6Clear = false;')
    budget_values = {
        'LOW': {'GI_VOLUME_SIZE':24,'LOCAL_LIGHT_COUNT':16,'LOCAL_SHADOW_RESOLUTION':64},
        'MEDIUM': {'GI_VOLUME_SIZE':32,'LOCAL_LIGHT_COUNT':32,'LOCAL_SHADOW_RESOLUTION':128},
        'HIGH': {'GI_VOLUME_SIZE':40,'LOCAL_LIGHT_COUNT':64,'LOCAL_SHADOW_RESOLUTION':128},
        'ULTRA': {'GI_VOLUME_SIZE':48,'LOCAL_LIGHT_COUNT':64,'LOCAL_SHADOW_RESOLUTION':192},
    }
    for name, value in budget_values[preset].items():
        settings = re.sub(r'(#define '+name+r')\s+[^\n]+', r'\g<1> '+str(value), settings)
    reflection_budget = {
        'LOW': (0.5, 1, 16, 4),
        'MEDIUM': (0.5, 1, 32, 8),
        'HIGH': (1.0, 2, 64, 12),
        'ULTRA': (1.0, 4, 96, 16),
    }
    reflection_scale, directions, screen_steps, history = reflection_budget[preset]
    contract['reflection'] = {
        'scale': reflection_scale,
        'directions': directions,
        'screen_steps': screen_steps,
        'world_steps': {'LOW':32, 'MEDIUM':64, 'HIGH':96, 'ULTRA':128}[preset],
        'history_frames': history,
        'history_target': 'colortex7',
        'water_packet_target': 'colortex5',
    }
    # The probe contract allocates full-size scene attachments. The complete
    # renderer gives reflection history its actual quality-dependent dimensions.
    for allocation in contract['allocations']:
        if allocation['name'] in ('colortex7_A', 'colortex7_B'):
            allocation['width'] = max(1, int(contract['viewport'][0] * reflection_scale))
            allocation['height'] = max(1, int(contract['viewport'][1] * reflection_scale))
            allocation['bytes'] = allocation['width'] * allocation['height'] * 16
    contract['allocated_bytes'] = sum(item['bytes'] for item in contract['allocations'])
    (target/'world-layout.json').write_text(json.dumps(contract, indent=2)+'\n')
    settings = re.sub(r'(#define (?:WATER|MATERIAL)_REFLECTION_STEPS)\s+[^\n]+',
                      r'\g<1> '+str(screen_steps), settings)
    settings = settings.replace('const int colortex7Format = RGBA16F;',
                                'const int colortex7Format = RGBA32F;')
    settings = settings.replace('const bool colortex7Clear = true;',
                                'const bool colortex7Clear = false;')
    # Keep declarations within SETTINGS_GLSL; J9 resolves relative and absolute
    # include spellings separately, unlike the offline include expander.
    settings = re.sub(r'^const int shadowMapResolution[^\n]+',
        'const int shadowMapResolution = '+str(contract['capture']['width'])+';', settings, flags=re.M)
    (target/'settings.glsl').write_text(settings)
    (target/'lib/companion_lighting.glsl').write_text('#include "/lib/world/lighting_backend.glsl"\n')

    # Sky strips move to the fixed world atlas. Attachment 4 is raw opaque HDR
    # (also bound in gbuffers), while 3 preserves its composed display background.
    for path in (target/'lib').glob('*.glsl'):
        source = path.read_text()
        if path.name in ('sky_noise.glsl','cloud_density.glsl','sky.glsl'):
            source = source.replace('noisetex', 'shadowcolor0')
        if path.name == 'noise.glsl':
            source = source.replace('noisetex', 'shadowcolor0')
        if path.name == 'ore_emission.glsl':
            source = source.replace('#include "companion_lighting.glsl"',
                '#include "companion_lighting.glsl"\n#include "/lib/world/ore_emission.glsl"')
        if path.name == 'material_reflection.glsl':
            source = source.replace('#include "reflection_medium.glsl"',
                '#include "reflection_medium.glsl"\n#include "/lib/world/reflection_material.glsl"')
        if path.name == 'water_reflection.glsl':
            source = source.replace('colortex6', 'colortex4')
        if path.name == 'underwater.glsl':
            source = source.replace('colortex6', 'colortex3')
        if path.name in ('shadow.glsl','shadow_filter.glsl','foliage_lighting.glsl','reflection_occlusion.glsl'):
            source = replace_texture_calls(source)
        if path.name == 'shadow_filter.glsl':
            source = source.replace('uniform sampler2D shadowcolor1;',
                'uniform sampler2D shadowcolor1;\n#include "/lib/world/solar.glsl"')
        if path.name in ('sky.glsl','air_shadow.glsl'):
            source = source.replace('max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0))',
                                    'vec2(worldRegion(WORLD_REGION_SKY_CACHE).zw) * 0.5')
            source = source.replace('uniform sampler2D colortex3;',
                '#include "/lib/world/layout.glsl"\n#include "/lib/world/storage.glsl"')
            source = re.sub(r'texture2D\(colortex3, (.*?) / vec2\(viewWidth, viewHeight\)\)',
                r'texture2D(colortex6, (vec2(worldRegion(WORLD_REGION_SKY_CACHE).xy) + \1) / vec2(textureSize(colortex6, 0)))', source)
            if path.name == 'air_shadow.glsl':
                source = source.replace('vec2 uv = (vec2(size.x, 0.0) + pixel) / vec2(viewWidth, viewHeight);',
                    'vec2 uv = (vec2(worldRegion(WORLD_REGION_SKY_CACHE).xy) + vec2(size.x, 0.0) + pixel) / vec2(textureSize(colortex6, 0));')
                source = source.replace('texture2D(field, uv)', 'texture2D(colortex6, uv)')
                source = source.replace('#include "cloud_density.glsl"',
                    '#include "cloud_density.glsl"\n#include "/lib/world/layout.glsl"\n#include "/lib/world/storage.glsl"')
        if path.name == 'space.glsl':
            source = source.replace('float(shadowMapResolution)', 'float(WORLD_CAPTURE_SOLAR.z)')
            source = source.replace('#include "uniforms.glsl"',
                '#include "uniforms.glsl"\n#include "/lib/world/layout.glsl"')
        source = vertex_symbols(source)
        source = re.sub(r'\bvarying\b', 'SIMPLE_VARYING', source)
        source = re.sub(r'gl_FragData\[(\d)\]', r'fullOut\1', source)
        source = re.sub(r'\btexture\b', 'gtexture', source)
        source = source.replace('texture2DLod(', 'textureLod(').replace('texture2D(', 'texture(')
        (path).write_text(source)

    if world_reflections:
        (target/'lib/reflection_occlusion.glsl').write_text(
            '#include "/lib/world/reflection_occlusion.glsl"\n')
        path = target/'lib/screen_reflection.glsl'
        source = path.read_text()
        # Hidden background depths from previous screen pixels are not geometry.
        # Only actual screen intersections and world hits may supply radiance.
        first = source.index('        float behind = rayDepth - coveredDepth;')
        last = source.index('        previousT = t;', first)
        source = source[:first]+source[last:]
        path.write_text(source)
        if planar_reflections:
            path = target/'lib/water_reflection.glsl'
            source = path.read_text()
            source = source.replace('#include "reflection_source.glsl"',
                '#include "reflection_source.glsl"\n#include "/lib/world/reflection_hybrid.glsl"\n#include "/lib/world/reflection_planar.glsl"')
            first = source.index('    ScreenReflectionHit traced =', source.index('vec4 traceWaterScene('))
            last = source.index('\n}', first)
            source = source[:first]+"""    vec4 planar = worldPlanarReflection(colortex4, depthtex1, origin, direction, roughness, far, distanceToHit);
        if (planar.a > 0.0) return planar;
        return worldHybridReflection(colortex4, depthtex1, origin, direction, 0.001,
            far, WATER_REFLECTION_STEPS, waterPlane, distanceToHit);"""+source[last:]
            path.write_text(source)
            path = target/'lib/material_reflection.glsl'
            source = path.read_text().replace('#include "reflection_source.glsl"',
                '#include "reflection_source.glsl"\n#include "/lib/world/reflection_hybrid.glsl"')
            first = source.index('    distanceToHit = 0.0;', source.index('vec4 traceMaterialScene('))
            last = source.index('\n}', first)
            source = source[:first]+"""    return worldHybridReflection(scene, depths, origin, direction, 0.001,
            far, MATERIAL_REFLECTION_STEPS, vec4(0.0), distanceToHit);"""+source[last:]
            path.write_text(source)
        steps = {'LOW':32,'MEDIUM':64,'HIGH':96,'ULTRA':128}[preset]
        path = target/'lib/world/reflection_query.glsl'
        path.write_text(path.read_text().replace('#define WORLD_REFLECTION_STEPS 64',
                                               '#define WORLD_REFLECTION_STEPS '+str(steps)))

    path = target/'lib/screen_reflection_adaptive.glsl'
    source = path.read_text().replace('#include "space.glsl"',
        '#include "space.glsl"\n#include "/lib/world/reflection_background.glsl"')
    source = source.replace('// WORLD_BACKGROUND_RECONSTRUCTION',
        'if (foregroundDepth > 0.0) {\n'
        '        vec4 recovered = reflectionKnownBackground(scene, depths, foregroundUv, foregroundDepth,\n'
        '            origin, direction, maximum, clipPlane);\n'
        '        if (recovered.a > 0.0) return screenReflectionHit(recovered, 0.2, false);\n'
        '    }')
    path.write_text(source)

    # Reuse original program entry points, modernizing their shared bodies once.
    for path in (ROOT/'shaders/program').glob('*.glsl'):
        if path.name.startswith('world_') or path.name.startswith('shadow.'):
            continue
        stage = path.name.split('.')[-2]
        source = path.read_text()
        if path.name == 'deferred1.fsh.glsl':
            source = source.replace('RENDERTARGETS: 6,0,1,2', 'RENDERTARGETS: 4,0,1,2,3,5')
            source = source.replace('gl_FragData[0] = reflectionSource;',
                'gl_FragData[0] = reflectionSource;\n    gl_FragData[4] = vec4(color, 1.0);')
        if path.name == 'gbuffers_water.vsh.glsl':
            source = source.replace('#include "../lib/water.glsl"',
                '#include "../lib/water.glsl"\n#include "/lib/world/water_boundary.glsl"')
            source = source.replace('getWaterWaveHeight(worldXZ, frameTimeCounter);',
                'getWaterWaveHeight(worldXZ, frameTimeCounter) * worldWaterShoreWeight(playerPos, cameraPosition);')
        if path.name == 'gbuffers_water.fsh.glsl':
            source = source.replace('RENDERTARGETS: 0,1,2,5,7', 'RENDERTARGETS: 0,1,2,5')
            source = source.replace('colortex6', 'colortex4')
            source = source.replace('#include "../lib/water_surface.glsl"',
                '#include "../lib/water_surface.glsl"\n#include "/lib/world/water_boundary.glsl"')
            source = source.replace('float orientation = isEyeInWater',
                'float boundary = worldWaterShoreWeight(viewToWorld(vViewPos), cameraPosition);\n'
                '        waveNormalWorld = normalize(mix(vec3(0.0, 1.0, 0.0), waveNormalWorld, boundary));\n'
                '        float orientation = isEyeInWater')
        if path.name == 'composite2.fsh.glsl':
            source = source.replace('colortex6MipmapEnabled', 'colortex3MipmapEnabled')
        (target/'program'/path.name).write_text(modernize(source, stage))

    # Each stage reads the same generated resource contract. World prepare
    # programs take the ordinary artistic/transport settings as well.
    for dimension in ('', 'world-1', 'world1'):
        folder = target/dimension
        light_layout = target/'lib/world/light_layout.glsl'
        if dimension == '' and planar_reflections:
            source = light_layout.read_text()
            previous = contract['point_shadow_invocations']
            source = source.replace('#define WORLD_POINT_SHADOW_INVOCATIONS '+str(previous),
                                    '#define WORLD_POINT_SHADOW_INVOCATIONS '+str(previous+1))
            source = source.replace('#define WORLD_CAPTURE_INVOCATIONS '+str(previous+1),
                                    '#define WORLD_CAPTURE_INVOCATIONS '+str(previous+2))
            light_layout.write_text(source)
        for path in folder.glob('shadow.?sh'):
            source = path.read_text()
            source = source.replace('#define WORLD_FULL_RENDERER (1)',
                '#define WORLD_FULL_RENDERER (1)\n#define WORLD_PLANAR_REFLECTION (1)')
            first = source.index('\n') + 1
            defines = '#define WORLD_FULL_RENDERER (1)\n'
            if planar_reflections:
                defines += '#define WORLD_PLANAR_REFLECTION (1)\n'
            path.write_text(source[:first] + defines + source[first:])
        for path in folder.glob('prepare*.fsh'):
            source = path.read_text().replace('#version 330 core\n',
                '#version 330 core\n#define WORLD_FULL_RENDERER (1)\n#include "/settings.glsl"\n')
            # settings owns the cache format/clear declaration in a full pack.
            source = source.replace('const bool colortex6Clear = false;', '')
            path.write_text(source)
        if planar_reflections:
            # Plane selection runs after world publication. A paired local copy
            # leaves the persistent banks consistent before scene geometry starts.
            last_prepare = max(int(path.stem.removeprefix('prepare') or '0') for path in folder.glob('prepare*.fsh'))
            control = contract['persistent']['regions']['planar_control']
            from .migration_platform import FULLSCREEN
            vertex = FULLSCREEN
            body = ('vec2 corner = gl_Position.xy * 0.5 + 0.5;\n'
                f'    gl_Position.xy = (vec2({control["x"]}.0,{control["y"]}.0) + corner * vec2(8.0,1.0))'
                f' / vec2({contract["persistent"]["width"]}.0,{contract["persistent"]["height"]}.0) * 2.0 - 1.0;\n')
            end = vertex.rfind('}')
            vertex = vertex[:end]+body+vertex[end:]
            for offset, name in enumerate(('world_planar_select','world_copy'), 1):
                (folder/('prepare'+str(last_prepare+offset)+'.vsh')).write_text(vertex)
                (folder/('prepare'+str(last_prepare+offset)+'.fsh')).write_text('#version 330 core\n'
                    +(ROOT/'shaders/program'/ (name+'.fsh.glsl')).read_text())
            radiance = contract['persistent']['regions']['planar_radiance']
            vertex = FULLSCREEN
            body = ('vec2 corner = gl_Position.xy * 0.5 + 0.5;\n'
                f'    gl_Position.xy = (vec2({radiance["x"]}.0,{radiance["y"]}.0) + corner * vec2({radiance["width"]}.0,{radiance["height"]}.0))'
                f' / vec2({contract["persistent"]["width"]}.0,{contract["persistent"]["height"]}.0) * 2.0 - 1.0;\n')
            end = vertex.rfind('}')
            vertex = vertex[:end]+body+vertex[end:]
            for offset, name in enumerate(('world_planar_resolve','world_copy'), 3):
                (folder/('prepare'+str(last_prepare+offset)+'.vsh')).write_text(vertex)
                source = (ROOT/'shaders/program'/(name+'.fsh.glsl')).read_text()
                source = source.replace('const bool colortex6Clear = false;', '')
                (folder/('prepare'+str(last_prepare+offset)+'.fsh')).write_text('#version 330 core\n'
                    '#define WORLD_FULL_RENDERER (1)\n#include "/settings.glsl"\n'+source)
        for path in (ROOT/'shaders'/dimension).glob('*.*sh'):
            if path.stem == 'shadow':
                continue
            source = re.sub(r'^#version[^\n]+', '#version 330 core', path.read_text(), flags=re.M)
            path_out = folder/path.name
            path_out.write_text(source)
        # Share surface cloud shadows before gbuffers, independently of the
        # later volumetric sky cache. The following copy publishes both banks.
        cloud = contract['persistent']['regions']['cloud_shadow']
        last_prepare = max(int(path.stem.removeprefix('prepare') or '0') for path in folder.glob('prepare*.fsh'))
        from .migration_platform import FULLSCREEN
        vertex = FULLSCREEN
        body = ('vec2 corner = gl_Position.xy * 0.5 + 0.5;\n'
            f'    gl_Position.xy = (vec2({cloud["x"]}.0,{cloud["y"]}.0) + corner * vec2({cloud["width"]}.0,{cloud["height"]}.0))'
            f' / vec2({contract["persistent"]["width"]}.0,{contract["persistent"]["height"]}.0) * 2.0 - 1.0;\n')
        end = vertex.rfind('}')
        vertex = vertex[:end] + body + vertex[end:]
        for offset, name in enumerate(('world_cloud_shadow', 'world_copy'), 1):
            (folder/('prepare'+str(last_prepare+offset)+'.vsh')).write_text(vertex)
            source = (ROOT/'shaders/program'/(name+'.fsh.glsl')).read_text()
            source = source.replace('const bool colortex6Clear = false;', '')
            (folder/('prepare'+str(last_prepare+offset)+'.fsh')).write_text('#version 330 core\n'+source)

        # The logical sky draw is the only fixed-size deferred target.
        source = (ROOT/'shaders/program/deferred.fsh.glsl').read_text()
        source = source.replace('RENDERTARGETS: 3', 'RENDERTARGETS: 6')
        source = source.replace('../lib/', '/lib/')
        source = source.replace('max(floor(vec2(viewWidth, viewHeight) * 0.125), vec2(1.0))',
                                'vec2(worldRegion(WORLD_REGION_SKY_CACHE).zw) * 0.5')
        source = source.replace('gl_FragCoord.xy', 'localPixel')
        source = source.replace('void main() {',
            'void main() {\n    vec2 localPixel = gl_FragCoord.xy - vec2(worldRegion(WORLD_REGION_SKY_CACHE).xy);')
        source = source.replace('gl_FragCoord.x','localPixel.x').replace('gl_FragCoord.y','localPixel.y')
        source = source.replace('vec2 localPixel = localPixel.xy', 'vec2 localPixel = gl_FragCoord.xy')
        (folder/'deferred.fsh').write_text('#version 330 core\n'+modernize(source,'fsh'))
        sky = contract['persistent']['regions']['sky_cache']
        width,height = contract['persistent']['width'],contract['persistent']['height']
        vertex = (target/'program/deferred.vsh.glsl').read_text()
        clip = ('vec2 corner = gl_Position.xy * 0.5 + 0.5;\n'
                f'    gl_Position.xy = (vec2({sky["x"]}.0,{sky["y"]}.0) + corner * vec2({sky["width"]}.0,{sky["height"]}.0))'
                f' / vec2({width}.0,{height}.0) * 2.0 - 1.0;\n')
        last = vertex.rfind('}')
        (folder/'deferred.vsh').write_text('#version 330 core\n'+vertex[:last]+clip+vertex[last:])
        # A local sky draw flips the fixed attachment. A second sky-only copy
        # restores the bank containing the latest GI work, even at eight steps.
        (folder/'deferred2.vsh').write_text((folder/'deferred1.vsh').read_text())
        (folder/'deferred2.fsh').write_text((folder/'deferred1.fsh').read_text())
        (folder/'deferred1.vsh').write_text((folder/'deferred.vsh').read_text())
        (folder/'deferred1.fsh').write_text('#version 330 core\n'
            +(ROOT/'shaders/program/world_copy.fsh.glsl').read_text())
        # Build background support from opaque HDR before material reflections
        # consume it. Water and glass then use the same current-frame samples.
        (folder/'deferred4.vsh').write_text((folder/'deferred2.vsh').read_text())
        (folder/'deferred4.fsh').write_text((folder/'deferred2.fsh').read_text())
        background = contract['persistent']['regions']['reflection_background']
        from .migration_platform import FULLSCREEN
        vertex = FULLSCREEN
        body = ('vec2 corner = gl_Position.xy * 0.5 + 0.5;\n'
            f'    gl_Position.xy = (vec2({background["x"]}.0,{background["y"]}.0) + corner * vec2({background["width"]}.0,{background["height"]}.0))'
            f' / vec2({width}.0,{height}.0) * 2.0 - 1.0;\n')
        end = vertex.rfind('}')
        vertex = vertex[:end]+body+vertex[end:]
        for number, name in ((2,'world_reflection_background'),(3,'world_copy')):
            (folder/('deferred'+str(number)+'.vsh')).write_text(vertex)
            (folder/('deferred'+str(number)+'.fsh')).write_text('#version 330 core\n'
                +(ROOT/'shaders/program'/(name+'.fsh.glsl')).read_text())
        # Keep opaque display colour until refraction/underwater optics consume
        # it. Reflection queries still read the separate, nonrecursive source 3.
        # Only afterwards may cloud/shaft integration overwrite attachment 4.
        old = {number: {stage: (folder/('composite'+(str(number) if number else '')+'.'+stage)).read_text()
                        for stage in ('vsh', 'fsh')} for number in range(6)}
        for previous, current in ((0,3),(1,4),(3,6),(4,7),(5,8)):
            for stage in ('vsh','fsh'):
                (folder/('composite'+str(current)+'.'+stage)).write_text(old[previous][stage])
        for stage in ('vsh','fsh'):
            source = old[2][stage]
            first = source.index('\n')+1
            (folder/('composite2.'+stage)).write_text(source[:first]+'#define WORLD_BASE_OPTICS\n'+source[first:])
        (folder/'composite.vsh').write_text('#version 330 core\n'+modernize(FULLSCREEN,'vsh'))
        source = (ROOT/'shaders/program/world_water_reflection.fsh.glsl').read_text()
        (folder/'composite.fsh').write_text('#version 330 core\n'+modernize(source,'fsh'))
        # J9 starts the next frame from bank A. A paired copy publishes the
        # current reflection into both banks, exactly as for the world atlas.
        (folder/'composite1.vsh').write_text((folder/'composite.vsh').read_text())
        (folder/'composite1.fsh').write_text('#version 330 core\n/* RENDERTARGETS: 7 */\n'
            'uniform sampler2D colortex7;\nlayout(location=0) out vec4 result;\n'
            'void main() { result = texelFetch(colortex7, ivec2(gl_FragCoord.xy), 0); }\n')
        (folder/'composite5.vsh').write_text(old[2]['vsh'])
        source = (ROOT/'shaders/program/world_media_composite.fsh.glsl').read_text()
        (folder/'composite5.fsh').write_text('#version 330 core\n'+modernize(source,'fsh'))
        if dimension:
            definition = '#define SIMPLE_DIMENSION ('+('-1' if dimension=='world-1' else '1')+')\n'
            for path in folder.glob('*.?sh'):
                source = path.read_text()
                if 'SIMPLE_DIMENSION' not in source:
                    first = source.index('\n')+1
                    path.write_text(source[:first]+definition+source[first:])

    properties = (ROOT/'shaders/shaders.properties').read_text()
    properties = re.sub(r'^texture.noise=.*|^blend.shadow=.*|^scale.deferred=.*|^program.world[\-\d]+/shadow.enabled=.*',
                        '', properties, flags=re.M)
    # Assembly fixes capacities; expose artistic controls but prevent profiles
    # from selecting atlas dimensions that disagree with this generated pack.
    properties = re.sub(r'^profile\.[^\n]+\n', '', properties, flags=re.M)
    properties = re.sub(r'^blend\.gbuffers_water\.colortex7=[^\n]*\n', '', properties, flags=re.M)
    properties += ('\n#if DEBUG_VIEW == 0\n'
        'blend.gbuffers_textured.colortex1=ONE ONE ONE ONE\n'
        'blend.gbuffers_textured_lit.colortex1=ONE ONE ONE ONE\n#endif\n')
    properties = re.sub(r'^(scale\.composite)([0-5]?)(=)',
        lambda match: match[1]+str({0:3,1:4,3:6,4:7,5:8}[int(match[2] or 0)])+match[3],
        properties, flags=re.M)
    properties += f'\nsize.buffer.colortex7={reflection_scale} {reflection_scale}\n'
    properties += '\n'+generated_properties.replace('screen=WORLD_DEBUG_VIEW\n','').replace('clouds=off\n','')
    properties += ('\nuniform.int.worldTextureAtlas=12\n'
                   'texture.prepare.colortex5=textures/sky-noise.png\n'
                   'texture.gbuffers.shadowcolor0=textures/sky-noise.png\n'
                   'texture.deferred.shadowcolor0=textures/sky-noise.png\n'
                   'texture.composite.shadowcolor0=textures/sky-noise.png\n'
                   'texture.composite.depthtex2=minecraft:textures/atlas/blocks.png\n'
                   'texture.gbuffers.depthtex2=minecraft:textures/atlas/blocks.png\n')
    (target/'shaders.properties').write_text(properties)
    for dimension in ('', 'world-1', 'world1'):
        for path in (target/dimension).glob('*.?sh'):
            source = path.read_text()
            first = source.index('\n')+1
            prefix = ('#define WORLD_GPU_BACKEND (1)\n#define WORLD_FULL_RENDERER (1)\n'
                '#define WORLD_PACKED_WATER (1)\n#define WORLD_REFLECTION_CACHE (1)\n'
                f'#define WORLD_REFLECTION_DIRECTIONS {directions}\n'
                f'#define WORLD_REFLECTION_HISTORY {history}\n')
            path.write_text(source[:first]+prefix+source[first:])
            source = inline_shader(path, target)
            if path.suffix in ('.fsh', '.gsh'):
                # The global inline cap made terrain 31.9 ms instead of 3.4 ms
                # on RTX 4060. Native links without it took 3.42 s (terrain)
                # and 1.74 s (prepare); retain the guard on other large stages.
                limit_expansion = path.suffix == '.fsh' and path.stem not in ('gbuffers_terrain', 'prepare')
                source = mark_native_stage(source, fragment=limit_expansion)
            path.write_text(source)
    return contract


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=Path, required=True)
    parser.add_argument('--preset', choices=('LOW','MEDIUM','HIGH','ULTRA'), default='LOW')
    parser.add_argument('--world-reflections', action='store_true')
    parser.add_argument('--planar-reflections', action='store_true')
    args = parser.parse_args()
    build(args.target, args.preset, args.world_reflections, args.planar_reflections)
