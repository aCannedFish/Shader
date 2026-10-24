#include "/lib/world/gi_work.glsl"
/* RENDERTARGETS: 6 */
const bool colortex6Clear = false;
uniform sampler2D colortex6;
uniform sampler2D noisetex;
uniform sampler2D shadowtex0;
uniform vec3 cameraPosition;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform int frameCounter;
layout(location=0) out vec4 result;

// All working fields and their clock advance in one atlas draw. The source
// bank remains immutable throughout the draw; consumers see only whole cycles.
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    result = texelFetch(colortex6, pixel, 0);
    if (WORLD_GI_SUBSTEP >= GI_WORK_PER_FRAME || GI_BOUNCES == 0) return;
    WorldGiState state = worldGiState(colortex6);
    if (!state.valid || worldDecodeInt(worldGiHeader(colortex6, 9)) == frameCounter) return;
    bool first = state.bounce == 0 && state.iteration == 0;
    bool endBounce = state.iteration + 1 >= GI_PROPAGATION_STEPS;
    bool publish = endBounce && state.bounce + 1 >= GI_BOUNCES;
    ivec4 control = worldRegion(WORLD_REGION_GI_CONTROL);
    if (worldInsideRectangle(pixel, control)) {
        ivec2 local = pixel - control.xy;
        if (local.y != 0) return;
        WorldGiState next = state;
        next.iteration++;
        if (endBounce) {
            next.bounce++;
            next.iteration = 0;
        }
        if (publish) {
            next.bounce = 0;
            next.publishedOrigin = state.origin;
            next.origin = worldGiCurrentOrigin(colortex6);
            next.ready = true;
        }
        if (local.x == 9 && publish) result = worldEncodeInt(frameCounter);
        if (local.x == 0) result = vec4(1061.0, next.bounce, next.iteration, next.ready ? 1.0 : 0.0);
        if (local.x >= 1 && local.x <= 3) result = worldEncodeInt(next.origin[local.x - 1]);
        if (local.x >= 4 && local.x <= 6) result = worldEncodeInt(next.publishedOrigin[local.x - 4]);
        return;
    }
    const int fields[7] = int[7](WORLD_REGION_GI_PUBLISHED, WORLD_REGION_GI_PREVIOUS_BOUNCE,
        WORLD_REGION_GI_STEP, WORLD_REGION_GI_BOUNCE_SUM, WORLD_REGION_GI_TOTAL_SUM,
        WORLD_REGION_GI_SCENE, WORLD_REGION_GI_MEDIUM);
    int side = WORLD_GI_SIZE + 2;
    int bandHeight = side * ((WORLD_GI_SIZE + 7) / 8);
    for (int field = 0; field < 7; field++) {
        ivec4 rectangle = worldRegion(fields[field]);
        if (!worldInsideRectangle(pixel, rectangle)) continue;
        ivec2 local = pixel - rectangle.xy;
        int band = field < 5 ? local.y / bandHeight : 0;
        ivec2 slice = ivec2(local.x / side, (local.y % bandHeight) / side);
        ivec3 cell = ivec3(clamp(ivec2(local.x, local.y % bandHeight) % side - 1,
            ivec2(0), ivec2(WORLD_GI_SIZE - 1)), slice.x + slice.y * 8);
        if (cell.z >= WORLD_GI_SIZE) { result = vec4(0.0); return; }
        if (field >= 5) {
            if (first) {
                WorldGiVoxel voxel = worldGiLiveVoxel(colortex6, WorldPosition(state.origin + cell, vec3(0.5)));
                if (field == 5) result = vec4(voxel.albedo, voxel.material % 2048);
                else result = vec4(voxel.absorption, voxel.material / 2048 + voxel.state * 16
                    + int(round(clamp(voxel.skylight, 0.0, 1.0) * 15.0)) * 128);
            }
            return;
        }
        if (field == 0 && !publish) {
            if (!state.ready) result = vec4(0.0);
            return;
        }
        if (field == 1 && !endBounce) {
            if (first) result = vec4(0.0);
            return;
        }
        if (field == 4 && !endBounce) {
            if (first) result = vec4(0.0);
            return;
        }
        vec4 step = worldGiNextStep(colortex6, noisetex, shadowtex0, cell, band,
            state, cameraPosition, shadowModelView, shadowProjection);
        if (field == 2) { result = step; return; }
        vec4 sum = state.iteration == 0 ? step
            : worldGiCoefficient(colortex6, WORLD_REGION_GI_BOUNCE_SUM, cell, band) + step;
        if (field == 1 || field == 3) { result = sum; return; }
        vec4 total = state.bounce == 0 ? sum
            : worldGiCoefficient(colortex6, WORLD_REGION_GI_TOTAL_SUM, cell, band) + sum;
        result = total;
        return;
    }
    result = vec4(0.0);
}
