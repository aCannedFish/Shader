/* Propagate three source identities and low-energy diffuse radiance. Source IDs
 * are rebased with the stored origin and checked against current occupancy.
 * Fixed source emission prevents lamps feeding other colours into themselves.
 */
/* RENDERTARGETS: 8,10 */
#include "/lib/conventional_lpv.glsl"
layout(location=0) out vec4 result;
layout(location=1) out vec4 candidates;

#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
// Distinct sources are ranked by physical energy. Integer ties make the result
// independent of submission order and the order in which neighbours are read.
void lpvInsertSource(int identity, ivec3 cell, inout ivec3 selected, inout vec3 scores) {
    if (identity < 0 || any(equal(selected, ivec3(identity)))) return;
    ivec3 source = lpvCell(identity);
    uint material = lpvVoxel(source);
    if (lpvKind(material) != LPV_EMITTER) return;
    float distance = length(vec3(source - cell));
    float energy = lpvSourceEnergy(distance, lpvEmission(material));
    if (energy <= 0.000001) return;
    for (int index = 0; index < 3; index++) {
        if (energy > scores[index] || (energy == scores[index] && identity < selected[index])) {
            for (int shift = 2; shift > index; shift--) {
                selected[shift] = selected[shift - 1];
                scores[shift] = scores[shift - 1];
            }
            selected[index] = identity;
            scores[index] = energy;
            return;
        }
    }
}
#endif

void main() {
    result = vec4(0.0);
    candidates = vec4(0.0);
#if ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    int address = pixel.x + pixel.y * textureSize(colortex8, 0).x;
    if (address < LPV_HEADER_SIZE) {
        if (address == 0) {
            result = vec4(lpvShape().x, frameCounter % 1024, frameCounter / 1024, 1961.0);
            candidates = result;
        } else {
            // World coordinates live only in the full-float candidate texture.
            // Half-float C8 would round integers beyond 2048 and overflow later.
            candidates = vec4(lpvOrigin(cameraPosition), 1.0);
        }
        return;
    }
    int index = address - LPV_HEADER_SIZE;
    ivec3 shape = lpvShape();
    if (index >= shape.x * shape.y * shape.z) return;
    ivec3 cell = lpvCell(index);
    uint voxel = lpvVoxel(cell);
    uint kind = lpvKind(voxel);
    result.a = float(kind);
    if (kind == LPV_SOLID) return;
    ivec3 selected = ivec3(-1);
    vec3 scores = vec3(0.0);
    if (kind == LPV_EMITTER) lpvInsertSource(index, cell, selected, scores);
    vec3 light = vec3(0.0);
    if (lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) {
        ivec3 oldOrigin = ivec3(round(texelFetch(colortex10, ivec2(1, 0), 0).xyz));
        ivec3 shift = lpvOrigin(cameraPosition) - oldOrigin;
        ivec3 previous = cell + shift;
        for (int face = -1; face < 6; face++) {
            ivec3 neighbour = previous;
            if (face >= 0) neighbour[face / 2] += face % 2 == 0 ? 1 : -1;
            if (!lpvInside(neighbour)) continue;
            light += lpvReadCell(neighbour);
            vec3 stored = texelFetch(colortex10, lpvAddress(neighbour), 0).rgb;
            for (int entry = 0; entry < 3; entry++) {
                int identity = int(round(stored[entry])) - 1;
                if (identity < 0) continue;
                ivec3 source = lpvCell(identity) - shift;
                if (lpvInside(source)) lpvInsertSource(lpvIndex(source), cell, selected, scores);
            }
        }
        light *= 0.94 / 7.0;
    }
    vec3 colour = lpvColour(voxel);
    if (kind == LPV_GLASS) light *= colour * colour;
    if (kind == LPV_EMITTER) light = colour * colour * lpvEmission(voxel) / 15.0;
    result.rgb = min(light, vec3(16.0));
    candidates = vec4(vec3(selected + 1), 1.0);
#endif
}
