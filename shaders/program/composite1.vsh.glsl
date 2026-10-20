/* 相机位置决定的低频空气密度在全屏顶点上计算，避免每个体积片元重复读取
 * 相同的两个噪声纹素。各顶点的值一致，透视插值后仍为同一个帧内常量。
 */
#include "../lib/cloud_density.glsl"
varying float vAirDensityModulation;

void main() {
    gl_Position = ftransform();
    vAirDensityModulation = mix(0.98, 1.02, cloudVolumeNoise(cameraPosition / 2048.0).r);
}
