"""Prepare native OptiFine shader stages for the current renderer.

Include expansion, attribute conversion and J9 compatibility markers are shared
with archived migration tooling so the active pack has no world-atlas builder
or Minecraft model-catalogue dependency.
"""

import re


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
    if (alias >= 6000.0 && alias <= 6010.0) {
        alias = alias == 6000.0 || alias == 6003.0 || alias == 6010.0 ? 101.0 : 102.0;
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
