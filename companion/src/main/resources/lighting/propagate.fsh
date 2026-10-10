#version 330 core
#include "volume.glsl"
layout(location=0) out vec4 red;
layout(location=1) out vec4 green;
layout(location=2) out vec4 blue;
void main() {
    ivec3 cell=pixelVoxel(ivec2(gl_FragCoord.xy));
    red=green=blue=vec4(0);
    if (!insideVolume(cell) || voxel(cell).a>=1.0) { return; }
    for (int face=0;face<6;face++) {
        ivec3 neighbour=cell+ivec3(AXES[face]);
        if (!insideVolume(neighbour) || voxel(neighbour).a>=1.0) { continue; }
        vec3 direction=-AXES[face];
        vec3 radiance=fieldRadiance(neighbour,direction)*0.5;
        vec4 lobe=cosineLobe(direction);
        red += lobe*radiance.r;
        green += lobe*radiance.g;
        blue += lobe*radiance.b;
    }
}
