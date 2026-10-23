#include "/lib/world/coordinates.glsl"
#include "/lib/world/capture_layout.glsl"
layout(triangles) in;
layout(triangle_strip, max_vertices=15) out;
in WorldVertex {
    vec3 centre;
    vec3 position;
    vec2 uv;
    vec3 colour;
    float material;
    float light;
} vertex[];
uniform vec3 cameraPosition;
out vec2 sampleUv;
out vec3 sampleColour;
flat out int captureRoute;
flat out vec4 captureMetadata;

// Two 2x2 quads cover eight half-block cells. Face priority is independent of
// yaw, so overlapping submitted triangles cannot flicker with draw order.
void worldEmitRecord(ivec2 pixel, ivec2 size, int face) {
    for (int corner = 0; corner < 4; corner++) {
        ivec2 offset = ivec2(corner % 2, corner / 2) * size;
        vec2 ndc = vec2(pixel + offset) / float(WORLD_CAPTURE_SIDE) * 2.0 - 1.0;
        gl_Position = vec4(ndc, -0.98 + float(face) * 0.0001, 1.0);
        captureRoute = 1;
        sampleUv = (vertex[0].uv + vertex[1].uv + vertex[2].uv) / 3.0;
        sampleColour = (vertex[0].colour + vertex[1].colour + vertex[2].colour) / 3.0;
        captureMetadata = vec4(max(vertex[0].material, 0.0), vertex[0].light,
            float(face), 1.0);
        EmitVertex();
    }
    EndPrimitive();
}

void main() {
    captureRoute = 0;
    for (int index = 0; index < 3; index++) {
        vec4 clip = gl_in[index].gl_Position;
        clip.xy /= 0.05 + length(clip.xy) * 0.95;
        clip.z *= 0.2;
        vec2 logical = clip.xy / clip.w * 0.5 + 0.5;
        vec2 physical = (vec2(WORLD_CAPTURE_SOLAR.xy)
            + logical * vec2(WORLD_CAPTURE_SOLAR.zw)) / float(WORLD_CAPTURE_SIDE);
        clip.xy = (physical * 2.0 - 1.0) * clip.w;
        gl_Position = clip;
        captureRoute = 0;
        sampleUv = vertex[index].uv;
        sampleColour = vertex[index].colour;
        captureMetadata = vec4(0.0);
        EmitVertex();
    }
    EndPrimitive();
    vec3 normal = cross(vertex[1].position - vertex[0].position,
        vertex[2].position - vertex[0].position);
    float area = length(normal);
    if (area < 0.000001) return;
    normal /= area;
    int axis = abs(normal.y) > abs(normal.x) ? 1 : 0;
    if (abs(normal.z) > abs(normal[axis])) axis = 2;
    int face = axis * 2 + int(normal[axis] < 0.0);
    WorldPosition centre = worldPosition(vertex[0].centre + vec3(0.001), cameraPosition);
    captureRoute = 1;
    ivec3 nearOrigin = worldAlignedOrigin(cameraPosition, WORLD_NEAR_SHAPE, 2, 4);
    ivec3 nearCell = worldGridCell(centre, nearOrigin, 2);
    nearCell = worldFloorDivide(nearCell, 2) * 2;
    if (worldCellValid(nearCell, WORLD_NEAR_SHAPE)) {
        worldEmitRecord(worldCapturePixel(true, nearCell), ivec2(2), face);
        worldEmitRecord(worldCapturePixel(true, nearCell + ivec3(0, 0, 1)), ivec2(2), face);
    }
    ivec3 farOrigin = worldAlignedOrigin(cameraPosition, WORLD_FAR_SHAPE, 1, 4);
    ivec3 farCell = worldGridCell(centre, farOrigin, 1);
    if (worldCellValid(farCell, WORLD_FAR_SHAPE)) {
        worldEmitRecord(worldCapturePixel(false, farCell), ivec2(1), face);
    }
}
