"""Build an isolated J9 capability pack. This is not the migrated renderer.

A geometry stage emits solar triangles and 32^3 observed block records into
nonoverlapping shadow-map regions. prepare independently increments a persistent
fixed-size colour buffer. The readback helper never supplies scene data.
"""
from pathlib import Path
import shutil
import struct

VERTEX = '''#version 330 core
in vec3 vaPosition;
in vec4 vaColor;
in vec2 vaUV0;
in ivec2 vaUV2;
in vec3 mc_Entity;
in vec3 at_midBlock;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat4 shadowModelViewInverse;
uniform vec3 modelOffset;
uniform vec3 cameraPosition;
out VertexData {
    vec3 centre;
    vec2 uv;
    vec4 colour;
    float kind;
    float light;
} vertex;
void main() {
    vec4 position = modelViewMatrix * vec4(vaPosition + modelOffset, 1.0);
    gl_Position = projectionMatrix * position;
    vertex.centre = (shadowModelViewInverse * position).xyz + at_midBlock / 64.0;
    vertex.uv = vaUV0;
    vertex.colour = vaColor;
    vertex.kind = mc_Entity.x;
    ivec2 level = clamp(vaUV2 / 16, ivec2(0), ivec2(15));
    vertex.light = float(level.x + level.y * 16);
}
'''
GEOMETRY = '''#version 330 core
#include "/lib/world/coordinates.glsl"
layout(triangles) in;
layout(triangle_strip, max_vertices=7) out;
in VertexData {
    vec3 centre;
    vec2 uv;
    vec4 colour;
    float kind;
    float light;
} vertex[];
uniform vec3 cameraPosition;
out vec2 sampleUv;
out vec4 sampleColour;
flat out int route;
flat out vec4 recordPosition;
flat out vec4 recordSurface;
void main() {
    route = 0;
    for (int index = 0; index < 3; index++) {
        vec4 p = gl_in[index].gl_Position;
        p.xy /= 0.05 + length(p.xy) * 0.95;
        p.z *= 0.2;
        p.xy = p.xy * 0.5 - 0.5 * p.w;
        gl_Position = p;
        sampleUv = vertex[index].uv;
        sampleColour = vertex[index].colour;
        recordPosition = recordSurface = vec4(0.0);
        EmitVertex();
    }
    EndPrimitive();
    ivec3 origin = worldAlignedOrigin(cameraPosition, ivec3(32), 1, 4);
    vec3 cell = vec3(worldGridCell(worldPosition(vertex[0].centre + vec3(0.001), cameraPosition), origin, 1));
    if (any(lessThan(cell, vec3(0.0))) || any(greaterThanEqual(cell, vec3(32.0)))) return;
    float address = cell.x + cell.z * 32.0 + cell.y * 1024.0;
    vec2 pixel = vec2(mod(address, 512.0) + 1024.0, floor(address / 512.0));
    route = 1;
    for (int corner = 0; corner < 4; corner++) {
        vec2 offset = vec2(corner % 2, corner / 2);
        gl_Position = vec4((pixel + offset) / 2048.0 * 2.0 - 1.0, -0.9, 1.0);
        sampleUv = vertex[0].uv;
        sampleColour = vertex[0].colour;
        recordPosition = vec4(cell, 4242.0);
        recordSurface = vec4(vertex[0].uv, vertex[0].light, vertex[0].kind + 1024.0);
        EmitVertex();
    }
    EndPrimitive();
}
'''
FRAGMENT = '''#version 330 core
/* RENDERTARGETS: 0,1 */
/*
const int shadowcolor0Format = RGBA32F;
const int shadowcolor1Format = RGBA32F;
*/
const int shadowMapResolution = 2048;
const float shadowDistance = 96.0;
uniform sampler2D gtexture;
uniform float alphaTestRef;
in vec2 sampleUv;
in vec4 sampleColour;
flat in int route;
flat in vec4 recordPosition;
flat in vec4 recordSurface;
layout(location=0) out vec4 outColor0;
layout(location=1) out vec4 outColor1;
void main() {
    if (route == 1) {
        outColor0 = recordPosition;
        outColor1 = recordSurface;
        return;
    }
    if (texture(gtexture, sampleUv).a * max(sampleColour.a, 0.1) < alphaTestRef) discard;
    outColor0 = vec4(0.0, 0.0, 0.0, 1.0);
    outColor1 = vec4(0.0);
}
'''
BASE_VERTEX = '''#version 330 core
in vec3 vaPosition;
in vec4 vaColor;
in vec2 vaUV0;
uniform vec3 modelOffset;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
out vec2 uv;
out vec4 colour;
void main() {
    gl_Position = projectionMatrix * modelViewMatrix * vec4(vaPosition + modelOffset, 1.0);
    uv = vaUV0;
    colour = vaColor;
}
'''
BASE_FRAGMENT = '''#version 330 core
/* RENDERTARGETS: 0 */
/*
const int colortex0Format = RGBA16F;
*/
uniform sampler2D gtexture;
in vec2 uv;
in vec4 colour;
layout(location=0) out vec4 outColor0;
void main() {
    vec4 albedo = texture(gtexture, uv);
    if (albedo.a < 0.1) discard;
    outColor0 = vec4(albedo.rgb * colour.rgb, 1.0);
}
'''
FULLSCREEN = '''#version 120
void main() { gl_Position = ftransform(); }
'''
PREPARE = '''#version 330 core
#include "/lib/world/coordinates.glsl"
/* RENDERTARGETS: 6 */
/*
const int colortex6Format = RGBA32F;
*/
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform sampler3D noisetex;
uniform int frameCounter;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
layout(location=0) out vec4 outColor0;
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec4 header = texelFetch(colortex6, ivec2(0), 0);
    vec3 previous = texelFetch(colortex6, ivec2(1, 0), 0).xyz;
    bool valid = header.z == 1234.0;
    bool continuous = valid && worldFrameContinuous(cameraPosition, previous,
        frameCounter, int(header.y));
    uint generation = valid ? worldDecodeUint(texelFetch(colortex6, ivec2(3, 0), 0)) : 0u;
    if (!continuous) generation++;
    ivec3 origin = worldAlignedOrigin(cameraPosition, ivec3(32), 1, 4);
    outColor0 = vec4(0.0);
    if (pixel.y != 0) return;
    if (pixel.x == 0) outColor0 = vec4(valid ? header.x + 1.0 : 1.0,
        float(frameCounter), 1234.0, dot(texelFetch(noisetex, ivec3(0), 0), vec4(1.0)));
    if (pixel.x == 1) outColor0 = vec4(cameraPosition, 1.0);
    if (pixel.x == 2) outColor0 = vec4(previousCameraPosition, float(continuous));
    if (pixel.x == 3) outColor0 = worldEncodeUint(generation);
    if (pixel.x == 4) outColor0 = worldEncodeInt(origin.x);
    if (pixel.x == 5) outColor0 = worldEncodeInt(origin.y);
    if (pixel.x == 6) outColor0 = worldEncodeInt(origin.z);
    if (pixel.x == 7) {
        vec3 relative = vec3(-3.125, 1.25, 7.0625);
        WorldPosition position = worldPosition(relative, cameraPosition);
        outColor0 = vec4(worldCameraRelative(position, cameraPosition) - relative, 918.0);
    }
}
'''
FINAL = '''#version 330 core
uniform sampler2D colortex0;
uniform float viewWidth;
uniform float viewHeight;
layout(location=0) out vec4 outColor0;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth,viewHeight);
    outColor0 = vec4(texture(colortex0,uv).rgb,1.0);
}
'''


SHADOWCOMP = '''#version 330 core
/* RENDERTARGETS: 0,1 */
uniform sampler2D shadowcolor0;
uniform sampler2D shadowcolor1;
uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
layout(location=0) out vec4 outColor0;
layout(location=1) out vec4 outColor1;
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    outColor0 = texelFetch(shadowcolor0,pixel,0);
    outColor1 = texelFetch(shadowcolor1,pixel,0);
    if (pixel.y==2047) {
        if (pixel.x==2000) outColor1=texelFetch(colortex0,ivec2(0),0);
        if (pixel.x==2001) outColor1=texelFetch(colortex1,ivec2(0),0);
        if (pixel.x==2002) outColor1=texelFetch(colortex2,ivec2(0),0);
    }
}
'''


def build(root, target):
    """Generate only the stages needed to exercise the real loader contracts."""
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / 'shaders/block.properties', target / 'block.properties')
    (target / 'lib/world').mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / 'shaders/lib/world/coordinates.glsl', target / 'lib/world/coordinates.glsl')
    (target / 'shaders.properties').write_text('''shadow.culling=false
shadowTerrain=true
shadowTranslucent=true
shadowEntities=false
shadowBlockEntities=true
clouds=off
size.buffer.colortex6=32 32
texture.shadowcomp.colortex0=minecraft:textures/block/stone.png
texture.shadowcomp.colortex1=minecraft:textures/block/deepslate.png
texture.shadowcomp.colortex2=minecraft:textures/block/netherrack.png
texture.prepare.noisetex.1=textures/probe-state.bin TEXTURE_3D RGBA32F 2 1 1 RGBA FLOAT
''')
    (target/'textures').mkdir(exist_ok=True)
    (target/'textures/probe-state.bin').write_bytes(struct.pack('<8f',11,22,33,44,2047,4096,.125,1))
    for dimension in ('', 'world-1', 'world1'):
        folder = target / dimension
        folder.mkdir(exist_ok=True)
        for suffix, source in [('vsh',VERTEX),('gsh',GEOMETRY),('fsh',FRAGMENT)]:
            (folder / ('shadow.' + suffix)).write_text(source)
        for name in ('gbuffers_terrain','gbuffers_water','gbuffers_entities','gbuffers_block',
                     'gbuffers_basic','gbuffers_hand','gbuffers_textured','gbuffers_textured_lit'):
            (folder / (name + '.vsh')).write_text(BASE_VERTEX)
            (folder / (name + '.fsh')).write_text(BASE_FRAGMENT)
        (folder / 'shadowcomp.vsh').write_text(FULLSCREEN)
        (folder / 'shadowcomp.fsh').write_text(SHADOWCOMP)
        (folder / 'prepare.vsh').write_text(FULLSCREEN)
        (folder / 'prepare.fsh').write_text(PREPARE)
        (folder / 'final.vsh').write_text(FULLSCREEN)
        (folder / 'final.fsh').write_text(FINAL)


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[2]
    build(root, root / 'local-docs/migration/prototypes/P02/shaders')
