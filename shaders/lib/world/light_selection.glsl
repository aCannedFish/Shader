#ifndef SIMPLE_WORLD_LIGHT_SELECTION_GLSL
#define SIMPLE_WORLD_LIGHT_SELECTION_GLSL
#include "/lib/world/lookup.glsl"
#include "/lib/world/static.glsl"
#include "/lib/world/history.glsl"
#include "/lib/world/light_layout.glsl"

const int WORLD_LIGHT_HEADER_SIZE = 8;

struct WorldPointLight {
    WorldPosition position;
    vec3 emission;
    float radius;
    float level;
    bool valid;
};

ivec3 worldLightCell(int index) {
    return ivec3(index % WORLD_FAR_SHAPE.x,
        (index / WORLD_FAR_SHAPE.x) % WORLD_FAR_SHAPE.y,
        index / (WORLD_FAR_SHAPE.x * WORLD_FAR_SHAPE.y));
}

ivec2 worldLightTablePixel(int record) {
    ivec4 rectangle = worldRegion(WORLD_REGION_LIGHT_SELECTION);
    return rectangle.xy + ivec2(record % rectangle.z, record / rectangle.z);
}

ivec2 worldPreviousLightPixel(int record) {
    return worldRegion(WORLD_REGION_LIGHT_PREVIOUS).xy + ivec2(record, 0);
}

bool worldLightHistoryValid(sampler2D data, int frame) {
    vec4 header = texelFetch(data, worldPreviousLightPixel(0), 0);
    uint epoch = worldDecodeUint(texelFetch(data, worldPreviousLightPixel(2), 0));
    int previousFrame = worldDecodeInt(texelFetch(data, worldPreviousLightPixel(1), 0));
    return header.x == 905.0 && int(round(header.y)) == WORLD_POINT_LIGHT_COUNT
        && epoch == worldReadGeneration(data)
        && worldFrameFollows(frame, previousFrame);
}

ivec3 worldLightOrigin(sampler2D data, bool previous) {
    ivec2 first = previous ? worldPreviousLightPixel(3) : worldLightTablePixel(3);
    return ivec3(worldDecodeInt(texelFetch(data, first, 0)),
        worldDecodeInt(texelFetch(data, first + ivec2(1, 0), 0)),
        worldDecodeInt(texelFetch(data, first + ivec2(2, 0), 0)));
}

// Retain the original authored source anchor. Wall torches move towards their
// facing direction; this is immutable state metadata, not uploaded world data.
vec3 worldEmitterOffset(WorldDefinition definition) {
    vec3 offset = vec3(0.5, 0.72, 0.5);
    if ((definition.flags & 4096) != 0) {
        int direction = (definition.flags >> 13) & 3;
        if (direction < 2) offset.z += direction == 0 ? -0.20 : 0.20;
        else offset.x += direction == 2 ? -0.20 : 0.20;
    }
    return offset;
}

// Rank by distance and emission, with a small preference for an existing light.
// Integer priority survives half-float publication and keeps tree ties stable.
vec4 worldLightLeaf(sampler2D data, int index, vec3 camera, int frame) {
    int count = WORLD_FAR_SHAPE.x * WORLD_FAR_SHAPE.y * WORLD_FAR_SHAPE.z;
    if (index < 0 || index >= count) return vec4(0.0);
    ivec3 cell = worldLightCell(index);
    ivec2 pixel = worldVoxelAddress(cell, WORLD_FAR_SHAPE, 0, 0);
    ivec4 optics = ivec4(round(texelFetch(data, worldAtlasPixel(WORLD_REGION_FAR_OPTICS, pixel), 0)));
    if (optics.w == WORLD_UNKNOWN) return vec4(0.0);
    int material = optics.x + optics.y * 256;
    WorldDefinition definition = worldReadDefinition(data, material);
    // Animated emitters need their canonical block anchor, not the per-cell
    // envelope used for conservative occupancy. Do not duplicate an open lid.
    if (definition.emissionLevel <= 0 || ((definition.flags & 8) != 0 && (optics.z & 1024) == 0)) return vec4(0.0);
    ivec3 block = worldReadOrigin(data, false) + cell;
    vec3 relative = worldCameraRelative(WorldPosition(block, worldEmitterOffset(definition)), camera);
    float distanceSquared = dot(relative, relative);
    float radius = WORLD_POINT_LIGHT_RADIUS * max(float(definition.emissionLevel) / 15.0, 0.25);
    if (distanceSquared > (radius + 8.0) * (radius + 8.0)) return vec4(0.0);
    bool retained = false;
    if (worldLightHistoryValid(data, frame)) {
        ivec3 oldOrigin = worldLightOrigin(data, true);
        for (int slot = 0; slot < WORLD_POINT_LIGHT_COUNT; slot++) {
            vec4 previous = texelFetch(data, worldPreviousLightPixel(WORLD_LIGHT_HEADER_SIZE + slot * 4), 0);
            if (previous.w > 0.0 && all(equal(ivec3(round(previous.xyz)) + oldOrigin, block))) {
                retained = true;
                break;
            }
        }
    }
    float score = round(512.0 * float(definition.emissionLevel)
        * (retained ? 1.05 : 1.0) / (4.0 + distanceSquared));
    return vec4(float(index), 0.0, float(index + 1), max(score, 1.0));
}

// Nodes store a three-byte leaf identity and its exact integer priority. Empty
// branches contain zero; they cannot introduce a light from old allocation data.
vec4 worldLightNode(sampler2D data, int level, int index, vec3 camera, int frame) {
    if (level == 0) return worldLightLeaf(data, index, camera, frame);
    if (index < 0 || index >= worldLightLevelCount(level)) return vec4(0.0);
    ivec4 rectangle = worldRegion(WORLD_REGION_LIGHT_HIERARCHY);
    int address = worldLightLevelOffset(level) + index;
    vec4 record = texelFetch(data, rectangle.xy + ivec2(address % rectangle.z, address / rectangle.z), 0);
    int leaf = int(round(record.x)) + int(round(record.y)) * 256 + int(round(record.z)) * 65536;
    return vec4(float(index), float(level), float(leaf), record.w);
}

bool worldLightBetter(vec4 first, vec4 second) {
    return first.w > second.w || (first.w == second.w && first.z < second.z);
}

void worldLightQueueInsert(inout vec4 queue[64], inout int size, int capacity, vec4 node) {
    if (node.w <= 0.0 || capacity <= 0) return;
    if (size < capacity) {
        queue[size++] = node;
        return;
    }
    int worst = 0;
    for (int index = 1; index < 64; index++) {
        if (index >= size) break;
        if (worldLightBetter(queue[worst], queue[index])) worst = index;
    }
    if (worldLightBetter(node, queue[worst])) queue[worst] = node;
}

// Best-first extraction needs at most K frontier nodes for the Kth result.
// Every discarded subtree already has K distinct, brighter competitors. No
// hashing, source collision, frame-delayed insertion or CPU list is involved.
vec4 worldSelectLight(sampler2D data, int rank, vec3 camera, int frame) {
    vec4 queue[64];
    int size = 0;
    worldLightQueueInsert(queue, size, rank + 1,
        worldLightNode(data, WORLD_LIGHT_TREE_LEVELS, 0, camera, frame));
    for (int selected = 0; selected < 64; selected++) {
        if (size == 0) return vec4(0.0);
        int best = 0;
        for (int index = 1; index < 64; index++) {
            if (index >= size) break;
            if (worldLightBetter(queue[index], queue[best])) best = index;
        }
        vec4 node = queue[best];
        queue[best] = queue[--size];
        if (selected == rank) return node;
        int leaf = int(round(node.z)) - 1;
        int level = int(round(node.y));
        int parent = int(round(node.x));
        for (int step = 0; step < 12; step++) {
            if (level <= 0) break;
            int divisor = worldLightLeafSpan(level - 1);
            int childOnPath = leaf / divisor;
            for (int child = 0; child < 4; child++) {
                int index = parent * 4 + child;
                if (index == childOnPath) continue;
                worldLightQueueInsert(queue, size, rank - selected,
                    worldLightNode(data, level - 1, index, camera, frame));
            }
            parent = childOnPath;
            level--;
        }
    }
    return vec4(0.0);
}

int worldRankedLightLeaf(sampler2D data, int rank) {
    vec4 value = texelFetch(data, worldRegion(WORLD_REGION_LIGHT_RANKED).xy + ivec2(rank, 0), 0);
    int leaf = int(round(value.x)) + int(round(value.y)) * 256 + int(round(value.z)) * 65536;
    return value.w > 0.0 ? leaf - 1 : -1;
}

int worldRankForBlock(sampler2D data, ivec3 block) {
    ivec3 cell = block - worldReadOrigin(data, false);
    if (!worldCellValid(cell, WORLD_FAR_SHAPE)) return -1;
    int leaf = cell.x + WORLD_FAR_SHAPE.x * (cell.y + WORLD_FAR_SHAPE.y * cell.z);
    for (int rank = 0; rank < WORLD_POINT_LIGHT_COUNT; rank++) {
        if (worldRankedLightLeaf(data, rank) == leaf) return rank;
    }
    return -1;
}

int worldPreviousLightRank(sampler2D data, int slot) {
    vec4 record = texelFetch(data, worldPreviousLightPixel(WORLD_LIGHT_HEADER_SIZE + slot * 4), 0);
    if (record.w <= 0.0) return -1;
    return worldRankForBlock(data, worldLightOrigin(data, true) + ivec3(round(record.xyz)));
}

int worldMatchedLightRank(sampler2D data, int slot) {
    return int(round(texelFetch(data, worldRegion(WORLD_REGION_LIGHT_MATCHING).xy + ivec2(slot, 0), 0).x)) - 1;
}

// Keep sources in their existing slots, independently of distance ranking.
// New sources fill released slots immediately. This identity is also the key
// for independent shadow maps, so walking cannot attach one lamp's map to another.
int worldStableLightRank(sampler2D data, int slot, int frame) {
    if (!worldLightHistoryValid(data, frame)) return slot;
    int previous = worldMatchedLightRank(data, slot);
    if (previous >= 0) return previous;
    int freeRank = 0;
    for (int old = 0; old < WORLD_POINT_LIGHT_COUNT; old++) {
        if (old >= slot) break;
        if (worldMatchedLightRank(data, old) < 0) freeRank++;
    }
    int newRank = 0;
    for (int rank = 0; rank < WORLD_POINT_LIGHT_COUNT; rank++) {
        if (worldRankedLightLeaf(data, rank) < 0) break;
        bool retained = false;
        for (int old = 0; old < WORLD_POINT_LIGHT_COUNT; old++) {
            if (worldMatchedLightRank(data, old) == rank) {
                retained = true;
                break;
            }
        }
        if (retained) continue;
        if (newRank++ == freeRank) return rank;
    }
    return -1;
}

WorldPointLight worldReadPointLight(sampler2D data, int slot) {
    WorldPointLight result = WorldPointLight(WorldPosition(ivec3(0), vec3(0.0)),
        vec3(0.0), 0.0, 0.0, false);
    if (slot < 0 || slot >= WORLD_POINT_LIGHT_COUNT) return result;
    int first = WORLD_LIGHT_HEADER_SIZE + slot * 4;
    vec4 geometry = texelFetch(data, worldLightTablePixel(first), 0);
    vec4 emission = texelFetch(data, worldLightTablePixel(first + 1), 0);
    vec4 offset = texelFetch(data, worldLightTablePixel(first + 2), 0);
    result.position = WorldPosition(worldLightOrigin(data, false) + ivec3(round(geometry.xyz)), offset.xyz);
    result.emission = max(emission.rgb, vec3(0.0));
    result.radius = geometry.w;
    result.level = emission.w;
    result.valid = geometry.w > 0.0 && emission.w > 0.0;
    return result;
}
#endif
