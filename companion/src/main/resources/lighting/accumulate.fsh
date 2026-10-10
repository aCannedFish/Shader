#version 330 core
#include "volume.glsl"
layout(location=0) out vec4 red;
layout(location=1) out vec4 green;
layout(location=2) out vec4 blue;
void main() {
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    red=texelFetch(uFieldR,pixel,0)+texelFetch(uSeedR,pixel,0);
    green=texelFetch(uFieldG,pixel,0)+texelFetch(uSeedG,pixel,0);
    blue=texelFetch(uFieldB,pixel,0)+texelFetch(uSeedB,pixel,0);
}
