#version 330 core
#include "volume.glsl"
uniform sampler2D uShadowAtlas;
uniform ivec2 uAtlasSize;
uniform int uTilesAcross;
uniform int uResolution;
uniform int uSunTile;
uniform int uLightCount;
uniform int uBounce;
uniform float uReflectance;
uniform float uBlockStrength;
uniform vec3 uSunDirection;
uniform vec3 uSunColor;
uniform mat4 uSunMatrix;
#include "transmission_lookup.glsl"
layout(location=0) out vec4 red;
layout(location=1) out vec4 green;
layout(location=2) out vec4 blue;

// Row 0: block cell and signed radius, row 1: colour and emission, row 2: in-block offset.
vec4 lightData(int index, int row) {
    return texelFetch(uShadowAtlas,ivec2(4+index*3+row,0),0);
}
vec2 shadowUv(int tile,vec2 uv) {
    vec2 corner = vec2(tile % uTilesAcross, tile / uTilesAcross) * float(uResolution);
    corner.y += 16.0;
    float inner=float(uResolution-2);
    return (corner + 1.0 + clamp(uv,vec2(0.5/inner),vec2(1.0-0.5/inner))*inner) / vec2(uAtlasSize);
}
vec3 faceDirection(int face,vec2 uv) {
    vec2 p=uv*2.0-1.0;
    if (face==0) return normalize(vec3(1,-p.y,-p.x));
    if (face==1) return normalize(vec3(-1,-p.y,p.x));
    if (face==2) return normalize(vec3(p.x,1,p.y));
    if (face==3) return normalize(vec3(p.x,-1,-p.y));
    if (face==4) return normalize(vec3(p.x,-p.y,1));
    return normalize(vec3(-p.x,-p.y,-1));
}
vec3 pointVisibility(int index,vec3 delta,float radius,vec3 normal,vec3 transmission) {
    vec3 absolute = abs(delta);
    vec2 uv;
    int face;
    float axis;
    if (absolute.x >= absolute.y && absolute.x >= absolute.z) {
        axis = absolute.x;
        face = delta.x > 0.0 ? 0 : 1;
        uv = delta.x > 0.0 ? vec2(-delta.z,-delta.y) : vec2(delta.z,-delta.y);
    } else if (absolute.y >= absolute.z) {
        axis = absolute.y;
        face = delta.y > 0.0 ? 2 : 3;
        uv = delta.y > 0.0 ? vec2(delta.x,delta.z) : vec2(delta.x,-delta.z);
    } else {
        axis = absolute.z;
        face = delta.z > 0.0 ? 4 : 5;
        uv = delta.z > 0.0 ? vec2(delta.x,-delta.y) : vec2(-delta.x,-delta.y);
    }
    uv = uv / max(axis,0.001) * 0.5 + 0.5;
    float inner=float(uResolution-2);
    uv=clamp(uv,vec2(0.5/inner),vec2(1.0-0.5/inner));
    uv=(floor(uv*inner)+0.5)/inner;
    float plane=dot(faceDirection(face,uv),normal);
    float receiver=abs(plane)>0.0001 ? dot(delta,normal)/plane : length(delta);
    vec2 depths = texture(uShadowAtlas, shadowUv(index * 6 + face, uv)).rg;
    float distanceToReceiver = length(delta);
    float cosine = abs(dot(normal, delta)) / max(distanceToReceiver, 0.0001);
    float footprint = 2.0 * axis / inner;
    float bias = 0.012 + min(footprint * 0.6 / max(cosine, 0.35), 0.12);
    float query = (max(min(receiver, distanceToReceiver), 0.0) - bias) / radius;
    return step(query, depths.r) * (query < depths.g ? vec3(1.0) : transmission);
}
vec3 sunVisibility(vec3 position) {
    vec4 projected = uSunMatrix * vec4(position,1.0);
    vec3 uv = projected.xyz / projected.w * 0.5 + 0.5;
    if (any(lessThan(uv,vec3(0))) || any(greaterThan(uv,vec3(1)))) {
        return vec3(0.0);
    }
    vec2 depths = texture(uShadowAtlas, shadowUv(uSunTile, uv.xy)).rg;
    int index = int(texelFetch(uShadowAtlas, ivec2(3, 0), 0).x + 0.5);
    return step(uv.z - 0.0015, depths.r)
        * (uv.z < depths.g ? vec3(1.0) : cachedTransmission(index, position));
}
vec3 directLight(vec3 position,vec3 normal,float skylight) {
    vec3 result = uSunColor * max(dot(normal,uSunDirection),0.0)
                * sunVisibility(position) * smoothstep(0.5,0.95,skylight);
    for (int index=0;index<128;index++) {
        if (index>=uLightCount) { break; }
        vec4 light = lightData(index,0);
        vec3 delta = light.xyz+lightData(index,2).xyz-position;
        float distanceSquared = dot(delta,delta);
        float radius = abs(light.w);
        if (distanceSquared>=radius*radius) { continue; }
        float cutoff = 1.0-distanceSquared/(radius*radius);
        float cosine = max(dot(normal,normalize(delta)),0.0);
        vec3 visibility = pointVisibility(index, -delta, radius, normal,
            cachedTransmission(index, position));
        result += lightData(index,1).rgb * cutoff*cutoff / (1.0+distanceSquared)
                * cosine * visibility * uBlockStrength;
    }
    return result;
}
void main() {
    ivec3 cell = pixelVoxel(ivec2(gl_FragCoord.xy));
    red=green=blue=vec4(0);
    vec4 material = voxel(cell);
    if (!insideVolume(cell) || material.a>=1.0) { return; }
    float skylight = fract(material.a)*32.0/15.0;
    for (int face=0;face<6;face++) {
        ivec3 neighbour=cell+ivec3(AXES[face]);
        vec4 wall=voxel(neighbour);
        if (!insideVolume(neighbour) || wall.a<1.0) { continue; }
        vec3 normal=-AXES[face];
        vec3 radiance;
        if (uBounce==0) {
            vec3 position=vec3(cell)+0.5+AXES[face]*0.47;
            radiance=directLight(position,normal,skylight);
        } else {
            radiance=fieldIrradiance(cell,AXES[face]);
        }
        radiance *= min(wall.rgb,vec3(0.85))*uReflectance/3.14159265;
        vec4 lobe=cosineLobe(normal);
        red += lobe*radiance.r;
        green += lobe*radiance.g;
        blue += lobe*radiance.b;
    }
}
