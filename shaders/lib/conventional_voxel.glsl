/* Shadow vertices atomically publish a compact material per block. Priority is
 * deterministic: emitters, opaque geometry, then transmission. The second
 * fixed-size C5 image is detached from all raster attachments. Native shadow
 * drawing therefore cannot overwrite it, and front-end water data uses C9.
 */
#ifndef SIMPLE_CONVENTIONAL_VOXEL_GLSL
#define SIMPLE_CONVENTIONAL_VOXEL_GLSL
#include "/lib/conventional_lpv.glsl"

#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
// 任一原生模型顶点不在立方体角点时，整格遮挡证据即失效；partial投票优先。
// 使用实际几何属性，资源包改变模型后无需按方块名称维护分类表。
void lpvCaptureGeometry(vec3 centre, vec3 midBlock) {
    if (renderStage != 8 && renderStage != 9 && renderStage != 16) return;
    ivec3 cell = ivec3(floor(centre + 0.001)) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) return;
    bool corner = all(lessThan(abs(abs(midBlock) - vec3(32.0)), vec3(0.1)));
    ivec3 shape = lpvShape();
    int index = lpvIndex(cell) + shape.x * shape.y * shape.z;
    int width = imageSize(colorimg5).x;
    imageAtomicMax(colorimg5, ivec2(index % width, index / width), corner ? 1u : 2u);
}

uint lpvPackMaterial(vec3 colour, uint kind, int emission, bool solid) {
    uvec3 rgb = uvec3(round(clamp(colour, 0.0, 1.0) * 255.0));
    return (kind << 30u) | (uint(emission) << 24u) | (uint(solid) << 28u)
        | rgb.r | (rgb.g << 8u) | (rgb.b << 16u);
}

uint lpvVoxelMaterial(int id) {
    if (id == 6000) return lpvPackMaterial(vec3(1.0, 0.46, 0.12), LPV_EMITTER, 15, true);
    if (id == 6001) return lpvPackMaterial(vec3(0.10, 0.65, 1.0), LPV_EMITTER, 10, false);
    if (id == 6002) return lpvPackMaterial(vec3(1.0, 0.05, 0.01), LPV_EMITTER, 7, false);
    if (id == 6003) return lpvPackMaterial(vec3(0.55, 0.95, 0.82), LPV_EMITTER, 15, true);
    if (id == 6004) return lpvPackMaterial(vec3(0.92, 0.85, 1.0), LPV_EMITTER, 14, false);
    if (id == 6005) return lpvPackMaterial(vec3(0.48, 1.0, 0.35), LPV_EMITTER, 15, true);
    if (id == 6006) return lpvPackMaterial(vec3(1.0, 0.58, 0.90), LPV_EMITTER, 15, true);
    if (id == 6007) return lpvPackMaterial(vec3(0.68, 0.20, 1.0), LPV_EMITTER, 10, true);
    if (id == 6008) return lpvPackMaterial(vec3(1.0, 0.35, 0.08), LPV_EMITTER, 15, true);
    if (id == 6009) return lpvPackMaterial(vec3(0.68, 0.20, 1.0), LPV_EMITTER, 5, false);
    if (id == 6010 || id == 101) return lpvPackMaterial(vec3(1.0, 0.46, 0.12), LPV_EMITTER, 14, false);
    if (id == 102) return lpvPackMaterial(vec3(0.85, 0.80, 1.0), LPV_EMITTER, 14, false);
    if (id == 100 || id == 110) return lpvPackMaterial(vec3(0.90, 0.95, 1.0), LPV_GLASS, 0, false);
    if (id >= 200 && id < 300) return lpvPackMaterial(vec3(0.85, 0.95, 0.75), LPV_GLASS, 0, false);
    return lpvPackMaterial(vec3(0.0), LPV_SOLID, 0, true);
}

void lpvCaptureVertex(vec3 centre, int id) {
    // J9 interleaves ENTITIES=10, BLOCK_ENTITIES=11 and HAND_SOLID=15 between
    // terrain passes. Their vertices do not carry a valid terrain at_midBlock
    // or material attribute; accepting them creates moving solid/emitter cells.
    if (renderStage != 8 && renderStage != 9 && renderStage != 16) return;
    ivec3 cell = ivec3(floor(centre + 0.001)) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) return;
    int index = lpvIndex(cell);
    ivec2 size = imageSize(colorimg5);
    imageAtomicMax(colorimg5, ivec2(index % size.x, index / size.x), lpvVoxelMaterial(id));
}

// Diffuse GI needs the terrain's linear albedo and native skylight. The four
// emission bits are unused for ordinary solids and hold their sky level instead.
// Quantized atlas colours avoid texture-edge and vertex-order noise in the field.
void lpvCaptureSurface(vec3 centre, int id, vec3 albedo, float skyLevel) {
    if (renderStage != 8 && renderStage != 9 && renderStage != 16) return;
    ivec3 cell = ivec3(floor(centre + 0.001)) - lpvOrigin(cameraPosition);
    if (!lpvInside(cell)) return;
    uint material = lpvVoxelMaterial(id);
    if (lpvKind(material) == LPV_SOLID) {
        vec3 diffuse = floor(clamp(albedo, 0.0, 0.85) * 31.0 + 0.5) / 31.0;
        material = lpvPackMaterial(diffuse, LPV_SOLID, int(round(skyLevel * 15.0)), true);
    }
    int index = lpvIndex(cell);
    int width = imageSize(colorimg5).x;
    imageAtomicMax(colorimg5, ivec2(index % width, index / width), material);
}
#endif
#endif
