
/* 日月阴影深度阶段。按贴图 alpha 拒绝镂空部分，避免树叶和植物被当作完整实心面。
 * shadowcolor0 记录最近投影体：发光方块写显示空间颜色 (a=0.75，8 位保留暗部精度)，玻璃写透射色 (a=0.5)，
 * 水等其余半透明体写 (0, 0.5)，薄植被写 (0, 0.25)，不透明体写 (0, 1)。
 * 薄植被仅在其自身的逆光着色时使用类别；普通接收面仍按不透明遮挡处理。
 * 其余 alpha（含白色清屏值）一律视为不透明，
 * 保证类别缺失时阴影只会退回普通遮挡，不会被误补光。
 * OptiFine 会在 gl_FragData[0] 写入处注入 `if (a < alphaTestRef) discard;`，
 * 写 a=0 会连深度一起丢掉，不透明体便不再投影；所有标记的 alpha 都必须高于该阈值。
 */
/* DRAWBUFFERS:0 */

#include "../settings.glsl"
#include "../lib/uniforms.glsl"
#include "../lib/space.glsl"

uniform sampler2D texture;

varying vec2 vTexCoord;
varying vec4 vColor;
varying vec3 vShadowPosition;
varying float vCaster;

void main() {
    // 在 alpha 丢弃前求导，保证叶片边缘仍有完整的导数四像素组。
    vec3 plane = cross(dFdx(vShadowPosition), dFdy(vShadowPosition));
    float planeScale = max(max(abs(plane.x), abs(plane.y)), abs(plane.z));
    vec4 albedo = texture2D(texture, vTexCoord) * vColor;

    // 半透明像素直接丢弃，不写深度，也就不会投射阴影。
    if (albedo.a < alphaTestRef) {
        discard;
    }

    // 非线性畸变后的线性深度插值不再落在原始平面上，会产生圆斑状自阴影。
    // 反解当前纹素位置，再由原始平面求深度；掠射退化三角形保留光栅深度。
    gl_FragDepth = gl_FragCoord.z;
    if (abs(plane.z) > planeScale * 0.00001) {
        vec2 distorted = gl_FragCoord.xy / shadowTextureResolution() * 2.0 - 1.0;
        vec2 original = undistortShadow(distorted);
        float depth = vShadowPosition.z
                    - dot(plane.xy, original - vShadowPosition.xy) / plane.z;
        gl_FragDepth = clamp(depth * 0.5 + 0.5, 0.0, 1.0);
    }

    // 不透明表面保留原生材质颜色，供反射命中重建使用；alpha 类别不变。
    vec4 caster = vec4(albedo.rgb, 1.0);
    if (vCaster > 3.5) {
        caster = vec4(albedo.rgb, 0.25);
    } else if (vCaster > 2.5) {
        caster = vec4(0.0, 0.0, 0.0, 0.5);
    } else if (vCaster > 1.5) {
        // 与 Mod 的玻璃吸收同一经验式：饱和色调透射对应色光，浅色接近无色。
        float peak = max(max(albedo.r, albedo.g), albedo.b);
        vec3 hue = albedo.rgb / max(peak, 0.001);
        vec3 tint = (0.35 + 0.60 * peak) * (0.12 + 0.88 * pow(hue, vec3(1.5)));
        caster = vec4(clamp(tint, 0.0, 1.0), 0.5);
    } else if (vCaster > 0.5) {
        caster = vec4(albedo.rgb, 0.75);
    }
    gl_FragData[0] = caster;
}
