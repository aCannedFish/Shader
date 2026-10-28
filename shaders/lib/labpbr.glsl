/* LabPBR 1.3通用通道解码。不识别方块名称、矿石颜色或特定资源包。
 * specular与normal是线性数据贴图；albedo由调用者预先转为线性颜色。
 */
#ifndef LIB_LABPBR_GLSL
#define LIB_LABPBR_GLSL

struct LabPbrMaterial {
    vec3 albedo;
    vec3 f0;
    float roughness;
    float metallic;
    float emission;
    float porosity;
    float subsurface;
    vec3 tangentNormal;
    float ao;
    float height;
};

// 标准预定义金属的光学常数，不是按游戏方块分类的材质表。
vec3 labPbrConductorF0(int code, vec3 albedo) {
    vec3 n;
    vec3 k;
    if (code == 230) {
        n = vec3(2.9114, 2.9497, 2.5845);
        k = vec3(3.0893, 2.9318, 2.7670);
    }
    else if (code == 231) {
        n = vec3(0.18299, 0.42108, 1.3734);
        k = vec3(3.4242, 2.3459, 1.7704);
    }
    else if (code == 232) {
        n = vec3(1.3456, 0.96521, 0.61722);
        k = vec3(7.4746, 6.3995, 5.3031);
    }
    else if (code == 233) {
        n = vec3(3.1071, 3.1812, 2.3230);
        k = vec3(3.3314, 3.3291, 3.1350);
    }
    else if (code == 234) {
        n = vec3(0.27105, 0.67693, 1.3164);
        k = vec3(3.6092, 2.6248, 2.2921);
    }
    else if (code == 235) {
        n = vec3(1.9100, 1.8300, 1.4400);
        k = vec3(3.5100, 3.4000, 3.1800);
    }
    else if (code == 236) {
        n = vec3(2.3757, 2.0847, 1.8453);
        k = vec3(4.2655, 3.7153, 3.1365);
    }
    else if (code == 237) {
        n = vec3(0.15943, 0.14512, 0.13547);
        k = vec3(3.9291, 3.1900, 2.3808);
    }
    else {
        return clamp(albedo, 0.0, 1.0);
    }
    vec3 numerator = (n - 1.0) * (n - 1.0) + k * k;
    vec3 denominator = (n + 1.0) * (n + 1.0) + k * k;
    return numerator / denominator * clamp(albedo, 0.0, 1.0);
}

LabPbrMaterial decodeLabPbr(vec3 albedo, vec4 specularMap, vec4 normalMap) {
    LabPbrMaterial m;
    m.albedo = max(albedo, vec3(0.0));
    m.roughness = (1.0 - specularMap.r) * (1.0 - specularMap.r);
    int reflectance = int(floor(specularMap.g * 255.0 + 0.5));
    m.metallic = reflectance >= 230 ? 1.0 : 0.0;
    m.f0 = reflectance >= 230 ? labPbrConductorF0(reflectance, m.albedo) : vec3(specularMap.g);
    int blue = int(floor(specularMap.b * 255.0 + 0.5));
    m.porosity = reflectance < 230 && blue <= 64 ? float(blue) / 64.0 : 0.0;
    m.subsurface = reflectance < 230 && blue >= 65 ? float(blue - 65) / 190.0 : 0.0;
    int emissive = int(floor(specularMap.a * 255.0 + 0.5));
    m.emission = emissive < 255 ? float(emissive) / 254.0 : 0.0;
    // XY采用纹理坐标正方向的DirectX约定，切线基的bitangent须指向纹理V增大方向。
    vec2 xy = normalMap.rg * 2.0 - 1.0;
    float z = sqrt(max(1.0 - dot(xy, xy), 0.0));
    m.tangentNormal = normalize(vec3(xy, z));
    m.ao = clamp(normalMap.b, 0.0, 1.0);
    m.height = clamp(normalMap.a, 0.0, 1.0);
    return m;
}
#endif
