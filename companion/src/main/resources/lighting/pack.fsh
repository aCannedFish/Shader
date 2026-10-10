#version 330 core
#include "volume.glsl"
layout(location=0) out vec4 outputValue;
void main() {
    ivec2 pixel=ivec2(gl_FragCoord.xy);
    int side=uSize+2;
    int rows=(uSize+7)/8;
    int band=pixel.y/(rows*side);
    int localY=pixel.y % (rows*side);
    int z=(localY/side)*8+pixel.x/side;
    ivec3 cell=ivec3(clamp(pixel.x%side-1,0,uSize-1),
                     clamp(localY%side-1,0,uSize-1),clamp(z,0,uSize-1));
    ivec2 inputPixel=voxelPixel(cell);
    outputValue=band==0 ? texelFetch(uFieldR,inputPixel,0)
        : band==1 ? texelFetch(uFieldG,inputPixel,0) : texelFetch(uFieldB,inputPixel,0);
}
