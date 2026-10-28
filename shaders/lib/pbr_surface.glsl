/* 资源包驱动的通用不透明表面。材质贴图保持线性数据，颜色由调用者转为线性空间。 */
#ifndef LIB_PBR_SURFACE_GLSL
#define LIB_PBR_SURFACE_GLSL
#include "labpbr.glsl"
#include "material_lighting.glsl"
uniform sampler2D normals;
uniform sampler2D specular;

LabPbrMaterial readPbrSurface(vec3 albedo, vec2 uv) {
    vec4 normalMap = texture2D(normals, uv);
    if (dot(abs(normalMap), vec4(1.0)) < 0.00001) {
        normalMap = vec4(0.5, 0.5, 1.0, 1.0);
    }
    return decodeLabPbr(albedo, texture2D(specular, uv), normalMap);
}

// Bitangent指向纹理V增大方向，与LabPBR DirectX绿色通道约定一致。
vec3 pbrSurfaceNormal(vec3 geometric, vec3 position, vec2 uv, vec3 tangentNormal) {
    vec3 dx = dFdx(position);
    vec3 dy = dFdy(position);
    vec2 du = dFdx(uv);
    vec2 dv = dFdy(uv);
    float determinant = du.x * dv.y - du.y * dv.x;
    vec3 tangent = dx * dv.y - dy * du.y;
    vec3 bitangent = dy * du.x - dx * dv.x;
    if (abs(determinant) < 1e-12 || dot(tangent, tangent) < 1e-16) return geometric;
    tangent = normalize(tangent * sign(determinant));
    bitangent = safeNormalize(bitangent * sign(determinant), cross(geometric, tangent));
    return safeNormalize(mat3(tangent, bitangent, geometric) * tangentNormal, geometric);
}

SurfaceMaterial pbrBrdfMaterial(LabPbrMaterial pbr) {
    SurfaceMaterial m;
    m.f0 = pbr.f0;
    // 现有GGX内部将感知粗糙度平方为分布alpha，避免对LabPBR值重复平方。
    m.roughness = sqrt(max(pbr.roughness, 0.0));
    m.metallic = pbr.metallic;
    return m;
}

vec3 computePbrLighting(LabPbrMaterial pbr, vec3 normal, vec2 lightmap, vec3 shadow,
                       float occlusion, vec3 position, out vec3 reflectionSource) {
    SurfaceMaterial m = pbrBrdfMaterial(pbr);
    float strength = ENABLE_MATERIAL_REFLECTIONS == 1 ? MATERIAL_REFLECTION_STRENGTH : 0.0;
    vec3 view = safeNormalize(-position, normal);
    bool reflective = max(max(m.f0.r, m.f0.g), m.f0.b) > 0.0001 && strength > 0.0;
    vec3 fraction = vec3(1.0);
    if (reflective) {
        fraction = mix(vec3(1.0), (1.0 - m.metallic)
            * (1.0 - materialFresnel(m.f0, dot(normal, view))), strength);
    }
    vec3 diffuse = computeSurfaceLighting(pbr.albedo * fraction, normal, lightmap, shadow,
        occlusion * pbr.ao, position);
    vec3 environment = vec3(0.0);
    vec3 direct = vec3(0.0);
    if (reflective) {
        vec3 direction = normalize(mat3(gbufferModelViewInverse) * reflect(-view, normal));
        environment = materialAmbientEnvironment(direction, lightmap)
            * materialEnvironmentWeight(m, dot(normal, view)) * strength;
        direct = materialDirectSpecular(m, normal, position, lightmap, shadow) * strength;
    }
    vec3 emission = pbr.albedo * pbr.emission * ORE_GLOW_STRENGTH * 4.0;
    reflectionSource = diffuse + environment + emission;
    return reflectionSource + direct;
}
#endif
