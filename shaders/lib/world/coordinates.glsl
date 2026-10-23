#ifndef SIMPLE_WORLD_COORDINATES_GLSL
#define SIMPLE_WORLD_COORDINATES_GLSL

// World positions use an integer block and a local fraction. Keys are relative
// to the loader's current coordinate frame; a discontinuity changes the epoch.
// Never add a camera-relative subpixel position to a large float world position.
struct WorldPosition {
    ivec3 block;
    vec3 fraction;
};

WorldPosition worldPosition(vec3 cameraRelative, vec3 camera) {
    ivec3 cameraBlock = ivec3(floor(camera));
    vec3 local = fract(camera) + cameraRelative;
    ivec3 carry = ivec3(floor(local));
    return WorldPosition(cameraBlock + carry, fract(local));
}

vec3 worldCameraRelative(WorldPosition position, vec3 camera) {
    return vec3(position.block - ivec3(floor(camera)))
        + position.fraction - fract(camera);
}

// GLSL integer division truncates toward zero. Grid alignment must use floor
// division so that the same volume contains both sides of a negative boundary.
int worldFloorDivide(int value, int divisor) {
    int quotient = value / divisor;
    int remainder = value % divisor;
    return quotient - int(remainder < 0);
}

ivec3 worldFloorDivide(ivec3 value, int divisor) {
    return ivec3(worldFloorDivide(value.x, divisor),
        worldFloorDivide(value.y, divisor), worldFloorDivide(value.z, divisor));
}

ivec3 worldAlignedOrigin(vec3 camera, ivec3 shape, int cellsPerBlock,
    int alignmentBlocks) {
    ivec3 aligned = worldFloorDivide(ivec3(floor(camera)), alignmentBlocks)
        * alignmentBlocks;
    return aligned * cellsPerBlock - shape / 2;
}

ivec3 worldGridCell(WorldPosition position, ivec3 origin, int cellsPerBlock) {
    return position.block * cellsPerBlock
        + ivec3(floor(position.fraction * float(cellsPerBlock))) - origin;
}

WorldPosition worldCellPosition(ivec3 cell, ivec3 origin,
    int cellsPerBlock, vec3 fraction) {
    ivec3 key = cell + origin;
    ivec3 block = worldFloorDivide(key, cellsPerBlock);
    vec3 within = (vec3(key - block * cellsPerBlock) + fraction)
        / float(cellsPerBlock);
    return WorldPosition(block, within);
}

bool worldCellValid(ivec3 cell, ivec3 shape) {
    return all(greaterThanEqual(cell, ivec3(0))) && all(lessThan(cell, shape));
}

// Linear records keep X contiguous, then Z, then Y. Invalid keys cannot alias
// another row. The inverse is useful for gather passes and GPU readback probes.
int worldCellIndex(ivec3 cell, ivec3 shape) {
    if (!worldCellValid(cell, shape)) {
        return -1;
    }
    return cell.x + shape.x * (cell.z + shape.z * cell.y);
}

ivec3 worldIndexCell(int index, ivec3 shape) {
    if (index < 0 || index >= shape.x * shape.y * shape.z) {
        return ivec3(-1);
    }
    return ivec3(index % shape.x, index / (shape.x * shape.z),
        (index / shape.x) % shape.z);
}

ivec2 worldRecordPixel(int index, int width) {
    return index < 0 ? ivec2(-1) : ivec2(index % width, index / width);
}

// Both half-float and full-float attachments represent every byte exactly.
// Large IDs, signed origins and generation counters therefore use four bytes.
vec4 worldEncodeUint(uint value) {
    return vec4(uvec4(value, value >> 8u, value >> 16u, value >> 24u)
        & uvec4(255u));
}

uint worldDecodeUint(vec4 bytes) {
    uvec4 value = uvec4(round(clamp(bytes, 0.0, 255.0)));
    return value.x | (value.y << 8u) | (value.z << 16u) | (value.w << 24u);
}

vec4 worldEncodeInt(int value) {
    return worldEncodeUint(uint(value));
}

int worldDecodeInt(vec4 bytes) {
    return int(worldDecodeUint(bytes));
}

// OptiFine J9 exposes rebased cameraPosition, without its absolute X/Z offset.
// Keep overlap for ordinary motion; discard frame-dependent history after large
// jumps, reloads or missing frames. A teleport is never guessed to be a rebase.
bool worldFrameContinuous(vec3 camera, vec3 previousCamera,
    int frame, int previousFrame) {
    int elapsed = (frame - previousFrame + 720720) % 720720;
    return elapsed == 1 && all(lessThanEqual(abs(camera - previousCamera), vec3(32.0)));
}

#endif
