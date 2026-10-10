/* Atlas coordinates and first-order spherical harmonic radiance transport. */
uniform int uSize;
uniform sampler2D uVoxels;
uniform sampler2D uFieldR;
uniform sampler2D uFieldG;
uniform sampler2D uFieldB;
uniform sampler2D uSeedR;
uniform sampler2D uSeedG;
uniform sampler2D uSeedB;
const vec3 AXES[6] = vec3[6](vec3(1,0,0),vec3(-1,0,0),vec3(0,1,0),
                             vec3(0,-1,0),vec3(0,0,1),vec3(0,0,-1));
ivec2 voxelPixel(ivec3 p) {
    return ivec2((p.z % 8) * uSize + p.x, (p.z / 8) * uSize + p.y);
}
ivec3 pixelVoxel(ivec2 pixel) {
    return ivec3(pixel.x % uSize, pixel.y % uSize,
                 (pixel.y / uSize) * 8 + pixel.x / uSize);
}
bool insideVolume(ivec3 p) {
    return all(greaterThanEqual(p,ivec3(0))) && all(lessThan(p,ivec3(uSize)));
}
vec4 voxel(ivec3 p) {
    return insideVolume(p) ? texelFetch(uVoxels,voxelPixel(p),0) : vec4(0,0,0,1);
}
vec4 cosineLobe(vec3 direction) {
    return vec4(0.886227, direction * 1.023327);
}
vec3 fieldRadiance(ivec3 p, vec3 direction) {
    vec4 basis = vec4(0.282095, direction * 0.488603);
    ivec2 pixel = voxelPixel(p);
    return max(vec3(dot(texelFetch(uFieldR,pixel,0),basis),
                    dot(texelFetch(uFieldG,pixel,0),basis),
                    dot(texelFetch(uFieldB,pixel,0),basis)),vec3(0));
}
vec3 fieldIrradiance(ivec3 p, vec3 direction) {
    vec4 basis = cosineLobe(direction);
    ivec2 pixel = voxelPixel(p);
    return max(vec3(dot(texelFetch(uFieldR,pixel,0),basis),
                    dot(texelFetch(uFieldG,pixel,0),basis),
                    dot(texelFetch(uFieldB,pixel,0),basis)),vec3(0));
}
