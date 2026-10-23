"""Build a native probe for independently blended shadow attachments.

The indexed blend must accumulate attachment zero while preserving every bit
of a finite RGBA32F payload in attachment one. The capture helper only reads the
published header; no test data is uploaded by a runtime helper.
"""
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]


def build(target):
    source = ROOT/'local-docs/migration/checkpoints/P04.2-uv/verified-native-pack'
    shutil.copytree(source, target, dirs_exist_ok=True)
    shutil.copy2(ROOT/'shaders/lib/world/raw_packing.glsl', target/'lib/world/raw_packing.glsl')
    with (target/'shaders.properties').open('a') as properties:
        properties.write('blend.shadow=ONE ONE\nblend.shadow.shadowcolor0=ONE ONE\nblend.shadow.shadowcolor1=off\n')
    for dimension in ('', 'world-1', 'world1'):
        folder = target/dimension
        geometry = folder/'shadow.gsh'
        text = geometry.read_text().replace('max_vertices=27', 'max_vertices=35')
        probe = '''
    if (gl_PrimitiveIDIn == 0) {
        for (int layer = 0; layer < 2; layer++) {
            for (int corner = 0; corner < 4; corner++) {
                ivec2 pixel = WORLD_CAPTURE_MATERIALS.xy + WORLD_CAPTURE_MATERIALS.zw - ivec2(2, 1);
                pixel += ivec2((corner % 2) * 2, corner / 2);
                gl_Position = vec4(vec2(pixel) / float(WORLD_CAPTURE_SIDE) * 2.0 - 1.0, layer == 0 ? -0.998 : -0.999, 1.0);
                captureRoute = 3;
                sampleUv = vec2(0.0);
                sampleColour = vec3(0.0);
                captureMetadata = captureU = captureV = vec4(0.0);
                EmitVertex();
            }
            EndPrimitive();
        }
    }
'''
        geometry.write_text(text.replace('void main() {', 'void main() {'+probe, 1))
        fragment = folder/'shadow.fsh'
        text = fragment.read_text()
        text = text.replace('void main() {', '''
#include "/lib/world/raw_packing.glsl"
#include "/lib/world/coordinates.glsl"
#include "/lib/world/capture_layout.glsl"
void main() {
    if (captureRoute == 3) {
        bool zero = int(gl_FragCoord.x) == WORLD_CAPTURE_MATERIALS.x + WORLD_CAPTURE_MATERIALS.z - 2;
        worldMaterial = zero ? vec4(0.0) : vec4(1.0, 2.0, 3.0, 0.0);
        worldOptics = worldRawEncode(uvec4(0x01234567u, 0x23456789u, 0x3456789au, 0x3fffffffu), true, true);
        return;
    }
''', 1)
        fragment.write_text(text)
        prepare = folder/'prepare.fsh'
        text = prepare.read_text().replace('#version 330 core',
            '#version 330 core\n#include "/lib/world/raw_packing.glsl"\n'
            'const vec4 shadowcolor0ClearColor = vec4(0.0, 0.0, 0.0, 0.0);', 1)
        probe = '''
    if (local.x >= 32 && local.x <= 44) {
        ivec2 address = WORLD_CAPTURE_MATERIALS.xy + WORLD_CAPTURE_MATERIALS.zw - ivec2(1);
        vec4 accumulation = texelFetch(shadowcolor0, address, 0);
        vec4 payload = texelFetch(shadowcolor1, address, 0);
        bool valid = worldRawValid(payload);
        uvec4 words = valid ? worldRawDecode(payload) : uvec4(0u);
        if (local.x == 32) result = accumulation;
        if (local.x >= 33 && local.x <= 36) result = vec4((words >> uint((local.x - 33) * 8)) & uvec4(255u));
        if (local.x == 37) result = vec4(float(valid), float(payload.x < 0.0), 719.0, 1.0);
        if (local.x == 38) result = texelFetch(shadowcolor0, address - ivec2(0, 1), 0);
        if (local.x >= 39) {
            vec4 zeroPayload = texelFetch(shadowcolor1, address - ivec2(1, 0), 0);
            bool zeroValid = worldRawValid(zeroPayload);
            uvec4 zeroWords = zeroValid ? worldRawDecode(zeroPayload) : uvec4(0u);
            if (local.x == 39) result = texelFetch(shadowcolor0, address - ivec2(1, 0), 0);
            if (local.x >= 40 && local.x <= 43) result = vec4((zeroWords >> uint((local.x - 40) * 8)) & uvec4(255u));
            if (local.x == 44) result = vec4(float(zeroValid), float(zeroPayload.x < 0.0), 720.0, 1.0);
        }
        return;
    }
'''
        prepare.write_text(text.replace('if (local.y != 0) return;', 'if (local.y != 0) return;'+probe, 1))
    return target


if __name__ == '__main__':
    build(ROOT/'local-docs/migration/prototypes/P04-shadow-blend-v3/shaders')
