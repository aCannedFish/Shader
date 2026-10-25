/* Extra shadow-geometry invocation: retain exact live UVs and alpha coverage
 * while projecting above-water terrain through a mirrored main camera.
 */
#ifndef SIMPLE_WORLD_PLANAR_CAPTURE_GLSL
#define SIMPLE_WORLD_PLANAR_CAPTURE_GLSL
#include "/lib/world/planar.glsl"
uniform mat4 gbufferModelView;
uniform mat4 gbufferPreviousProjection;

vec2 worldPlanarEncodeNormal(vec3 normal) {
    normal /= abs(normal.x) + abs(normal.y) + abs(normal.z);
    vec2 encoded = normal.xy;
    if (normal.z < 0.0) {
        vec2 signValue = vec2(encoded.x >= 0.0 ? 1.0 : -1.0, encoded.y >= 0.0 ? 1.0 : -1.0);
        encoded = (1.0 - abs(encoded.yx)) * signValue;
    }
    return encoded * 0.5 + 0.5;
}

void worldEmitPlanar() {
    int material = int(round(vertex[0].material));
    WorldDefinition definition = worldReadDefinition(colortex6, material);
    vec3 normal = cross(vertex[1].position - vertex[0].position, vertex[2].position - vertex[0].position);
    if (dot(normal, normal) < 1e-12) return;
    normal = normalize(normal);
    if (definition.legacy == 100) {
        if (normal.y < 0.999) return;
        vec2 uv[3];
        for (int index = 0; index < 3; index++) {
            vec4 clip = gbufferPreviousProjection * gbufferModelView * vec4(vertex[index].position, 1.0);
            if (clip.w <= 0.05) return;
            uv[index] = clamp(clip.xy / clip.w * 0.5 + 0.5, vec2(0.0), vec2(1.0));
        }
        vec2 a = uv[1] - uv[0];
        vec2 b = uv[2] - uv[0];
        float weight = abs(a.x * b.y - a.y * b.x) * 0.5;
        float height = cameraPosition.y + vertex[0].position.y;
        int bin = int(floor(height)) + 64;
        if (weight > 1e-10 && bin >= 0 && bin < 384) {
            worldEmitPacket(WORLD_CAPTURE_WATER_PLANES.xy + ivec2(bin, 0), ivec2(1),
                -0.9998, 5, vec4(weight * height, weight, 1.0, 0.0));
        }
        return;
    }
    if (definition.alphaType == 2 || !worldPlanarValid(colortex6, frameCounter, true)) return;
    float height = worldPlanarHeight(colortex6, true) - cameraPosition.y;
    float high = max(vertex[0].position.y, max(vertex[1].position.y, vertex[2].position.y));
    if (high < height) return;
    vec3 tint = (vertex[0].colour + vertex[1].colour + vertex[2].colour) / 3.0;
    ivec2 oct = ivec2(round(worldPlanarEncodeNormal(normal) * 255.0));
    int light = clamp(int(round(vertex[0].light)), 0, 255);
    float metadata = float(oct.x + oct.y * 256 + light * 65536);
    // Clip before mirroring. This preserves the water/land contact faces and
    // avoids depending on the loader's shadow-stage projection inverse in FS.
    vec3 positions[4];
    vec2 coordinates[4];
    int count = 0;
    for (int edge = 0; edge < 3; edge++) {
        int previous = (edge + 2) % 3;
        vec3 a = vertex[previous].position;
        vec3 b = vertex[edge].position;
        bool insideA = a.y >= height;
        bool insideB = b.y >= height;
        if (insideA != insideB) {
            float fraction = (height - a.y) / (b.y - a.y);
            positions[count] = mix(a, b, fraction);
            coordinates[count++] = mix(vertex[previous].uv, vertex[edge].uv, fraction);
        }
        if (insideB) {
            positions[count] = b;
            coordinates[count++] = vertex[edge].uv;
        }
    }
    if (count < 3) return;
    for (int corner = 0; corner < 4; corner++) {
        if (corner >= count) break;
        int index = count == 3 ? (corner == 0 ? 0 : corner == 1 ? 2 : 1)
            : (corner == 0 ? 0 : corner == 1 ? 3 : corner == 2 ? 1 : 2);
        vec3 position = positions[index];
        position.y = 2.0 * height - position.y;
        vec4 clip = gbufferPreviousProjection * gbufferModelView * vec4(position, 1.0);
        clip.xy *= WORLD_PLANAR_SCALE;
        vec2 logical = clip.xy / clip.w * 0.5 + 0.5;
        vec2 atlas = (vec2(WORLD_CAPTURE_PLANAR.xy)
            + logical * vec2(WORLD_CAPTURE_PLANAR.zw)) / float(WORLD_CAPTURE_SIDE);
        clip.xy = (atlas * 2.0 - 1.0) * clip.w;
        gl_Position = clip;
        sampleUv = coordinates[index];
        capturePayload = vec4(tint, metadata);
        captureRoute = 11;
        EmitVertex();
    }
    EndPrimitive();
}
#endif
