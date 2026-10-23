#ifndef SIMPLE_WORLD_HISTORY_GLSL
#define SIMPLE_WORLD_HISTORY_GLSL
#include "/lib/world/coordinates.glsl"
#include "/lib/world/layout.glsl"

// Snapshot identity is separate from the observation frame. Ordinary origin
// shifts preserve the epoch; jumps and changes to immutable tables reject it.
struct WorldFrame {
    bool valid;
    uint epoch;
    int frame;
    vec3 camera;
    ivec3 nearOrigin;
    ivec3 farOrigin;
    vec4 resourceStamp;
};

vec4 worldHeader(sampler2D data, int slot) {
    return texelFetch(data, worldRegion(WORLD_REGION_HEADER).xy + ivec2(slot, 0), 0);
}

WorldFrame worldPreviousFrame(sampler2D data) {
    WorldFrame previous = WorldFrame(false, 0u, -1, vec3(0.0), ivec3(0),
        ivec3(0), vec4(0.0));
    vec4 stamp = worldHeader(data, 0);
    if (any(isnan(stamp)) || any(isinf(stamp))) return previous;
    if (worldDecodeUint(stamp) != WORLD_LAYOUT_SIGNATURE) return previous;
    previous.epoch = worldDecodeUint(worldHeader(data, 8));
    if (previous.epoch == 0u) return previous;
    previous.valid = true;
    previous.frame = worldDecodeInt(worldHeader(data, 1));
    previous.epoch = worldDecodeUint(worldHeader(data, 8));
    previous.camera = vec3(worldDecodeInt(worldHeader(data, 9)),
        worldDecodeInt(worldHeader(data, 10)), worldDecodeInt(worldHeader(data, 11)))
        + worldHeader(data, 12).xyz;
    previous.nearOrigin = ivec3(worldDecodeInt(worldHeader(data, 2)),
        worldDecodeInt(worldHeader(data, 3)), worldDecodeInt(worldHeader(data, 4)));
    previous.farOrigin = ivec3(worldDecodeInt(worldHeader(data, 5)),
        worldDecodeInt(worldHeader(data, 6)), worldDecodeInt(worldHeader(data, 7)));
    previous.resourceStamp = worldHeader(data, 13);
    return previous;
}

uint worldFrameEpoch(WorldFrame previous, vec3 camera, int frame, vec4 resourceStamp) {
    if (!previous.valid) return 1u;
    bool continuous = worldFrameContinuous(camera, previous.camera, frame, previous.frame);
    return previous.epoch + uint(!continuous || any(notEqual(resourceStamp, previous.resourceStamp)));
}

// Compare a world cell with the same key in the previous volume. Comparing the
// same atlas address after an origin move would produce false edits and ghosts.
ivec3 worldPreviousCell(ivec3 cell, ivec3 origin, ivec3 oldOrigin) {
    return cell + origin - oldOrigin;
}

bool worldObservationChanged(vec4 oldMaterial, vec4 oldOptics,
    vec4 material, vec4 optics) {
    oldOptics.z = mod(round(oldOptics.z), 8.0);
    optics.z = mod(round(optics.z), 8.0);
    return any(notEqual(oldOptics, optics))
        || abs(oldMaterial.w - material.w) > 0.5
        || any(greaterThan(abs(oldMaterial.rgb - material.rgb), vec3(0.001)));
}
#endif
