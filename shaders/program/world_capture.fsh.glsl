/* RENDERTARGETS: 0,1 */
#ifdef WORLD_PACKED_UV
#include "/lib/world/raw_uv.glsl"
#endif
/*
const int shadowcolor0Format = RGBA32F;
const int shadowcolor1Format = RGBA32F;
*/
uniform sampler2D gtexture;
uniform float alphaTestRef;
in vec2 sampleUv;
in vec3 sampleColour;
flat in int captureRoute;
flat in vec4 captureMetadata;
flat in vec4 captureU;
flat in vec4 captureV;
layout(location=0) out vec4 worldMaterial;
layout(location=1) out vec4 worldOptics;

void main() {
    if (captureRoute == 2) {
#ifdef WORLD_PACKED_UV
        worldMaterial = vec4(0.0);
        worldOptics = worldRawEncodeUv(WorldUv(captureU.xyz, captureV.xyz,
            captureU.w == 517.0, captureV.w == 518.0));
#else
        worldMaterial = captureU;
        worldOptics = captureV;
#endif
        return;
    }
    vec4 texel = textureLod(gtexture, sampleUv, 0.0);
    if (captureRoute == 1) {
        // One alpha hole cannot remove the entire block observation. Exact
        // coverage is queried from the material separately after collection.
        worldMaterial = vec4(pow(max(texel.rgb * sampleColour, vec3(0.0)), vec3(2.2)),
            captureMetadata.y);
        worldOptics = vec4(captureMetadata.x, sampleUv, captureMetadata.z + 17.0);
        return;
    }
    if (texel.a < alphaTestRef) discard;
    worldMaterial = vec4(0.0, 0.0, 0.0, 1.0);
    worldOptics = vec4(0.0);
}
