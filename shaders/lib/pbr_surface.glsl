/* 资源包驱动的通用不透明表面。材质贴图保持线性数据，颜色由调用者转为线性空间。 */
#ifndef LIB_PBR_SURFACE_GLSL
#define LIB_PBR_SURFACE_GLSL
#include "labpbr.glsl"
#include "material_lighting.glsl"
uniform sampler2D normals;
uniform sampler2D specular;

// 高度数据的POM只在有效原生图集范围内步进。平坦高度直接退出，演示包没有额外成本。
vec2 pbrParallaxUv(vec2 uv, vec3 position, vec3 geometric, vec4 tile) {
#if POM_QUALITY == 0
    return uv;
#else
    vec3 dx = dFdx(position);
    vec3 dy = dFdy(position);
    vec2 du = dFdx(uv);
    vec2 dv = dFdy(uv);
    float determinant = du.x * dv.y - du.y * dv.x;
    vec3 tangent = dx * dv.y - dy * du.y;
    vec3 bitangent = dy * du.x - dx * dv.x;
    if (length(position) > POM_DISTANCE || min(tile.z, tile.w) <= 0.0
        || abs(determinant) < 1e-12 || dot(tangent, tangent) < 1e-16) return uv;
    tangent = normalize(tangent * sign(determinant));
    bitangent = safeNormalize(bitangent * sign(determinant), cross(geometric, tangent));
    vec3 view = safeNormalize(-position, geometric);
    vec3 viewTangent = vec3(dot(view, tangent), dot(view, bitangent), dot(view, geometric));
    if (viewTangent.z <= 0.08) return uv;
    float initialDepth = 1.0 - texture2D(normals, uv).a;
    if (initialDepth < 0.5 / 255.0) return uv;
#if POM_QUALITY == 1
    const int steps = 8;
#elif POM_QUALITY == 2
    const int steps = 16;
#else
    const int steps = 24;
#endif
    vec2 pixel = 0.5 / vec2(textureSize(normals, 0));
    vec2 minimum = tile.xy - tile.zw + pixel;
    vec2 maximum = tile.xy + tile.zw - pixel;
    vec2 direction = viewTangent.xy / viewTangent.z * tile.zw * 0.5;
    vec2 current = uv;
    vec2 previous = uv;
    float previousDifference = -initialDepth;
    float difference = previousDifference;
    for (int index = 1; index <= steps; index++) {
        float depth = float(index) / float(steps);
        vec2 candidate = uv - direction * depth;
        if (any(lessThan(candidate, minimum)) || any(greaterThan(candidate, maximum))) return current;
        previous = current;
        previousDifference = difference;
        current = candidate;
        difference = depth - (1.0 - texture2D(normals, current).a);
        if (difference >= 0.0) break;
    }
    float weight = clamp(difference / max(difference - previousDifference, 0.00001), 0.0, 1.0);
    return mix(current, previous, weight);
#endif
}

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
    m.roughness = max(sqrt(max(pbr.roughness, 0.0)), MATERIAL_GLOSS_ROUGHNESS);
    m.metallic = pbr.metallic;
    return m;
}

vec3 pbrGlossTangent(vec3 normal, vec3 position, vec2 uv) {
    vec3 tangent = dFdx(position) * dFdy(uv).y - dFdy(position) * dFdx(uv).y;
    vec3 fallback = abs(normal.y) < 0.9 ? cross(normal, vec3(0.0, 1.0, 0.0))
        : cross(normal, vec3(1.0, 0.0, 0.0));
    return safeNormalize(tangent - normal * dot(normal, tangent), normalize(fallback));
}

// 现有原生光源候选与逐灯透射缓存提供局部高光，完全不查询反射场景。
vec3 pbrLocalGloss(SurfaceMaterial m, vec3 normalView, vec3 tangentView, vec3 position, float anisotropy) {
#if defined(SIMPLE_VARYING) && (ENABLE_COLOURED_LIGHTING == 1 || GI_QUALITY > 0)
    if (!lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) return vec3(0.0);
    vec3 normal = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 tangent = normalize(mat3(gbufferModelViewInverse) * tangentView);
    vec3 view = normalize(mat3(gbufferModelViewInverse) * -position);
    vec3 world = viewToAbsoluteWorld(position) + normal * 0.04;
    vec3 receiver = world - vec3(lpvOrigin(cameraPosition));
    vec3 axis = abs(normal);
    vec3 plane = axis.x >= axis.y && axis.x >= axis.z ? vec3(0.0, 1.0, 1.0)
        : axis.y >= axis.z ? vec3(1.0, 0.0, 1.0) : vec3(1.0, 1.0, 0.0);
    vec3 first = plane.x > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 second = plane.z > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
    vec3 shifted = receiver - plane * 0.5;
    ivec3 base = ivec3(floor(shifted));
    vec2 fraction = vec2(dot(fract(shifted), first), dot(fract(shifted), second));
    vec3 sum = vec3(0.0);
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            ivec3 cell = base + ivec3(first) * x + ivec3(second) * y;
            if (!lpvInside(cell)) continue;
            float weight = (x == 0 ? 1.0 - fraction.x : fraction.x)
                * (y == 0 ? 1.0 - fraction.y : fraction.y);
            ivec2 address = lpvAddress(cell);
            vec3 candidates = texelFetch(colortex10, address, 0).rgb;
            for (int entry = 0; entry < 3; entry++) {
                int identity = int(round(candidates[entry])) - 1;
                if (identity < 0) continue;
                ivec3 source = lpvCell(identity);
                uint material = lpvVoxel(source);
                if (lpvKind(material) != LPV_EMITTER) continue;
                vec3 ray = vec3(source) + vec3(0.5, 0.72, 0.5) - receiver;
                float distance = length(ray);
                vec3 colour = lpvColour(material);
                colour *= colour;
#if ENABLE_COLOURED_LIGHTING == 0
                colour = vec3(luma(colour));
#endif
                vec3 transmission = texelFetch(colortex11,
                    address + ivec2(0, entry * textureSize(colortex8, 0).y), 0).rgb;
                vec3 radiance = colour * lpvSourceEnergy(distance, lpvEmission(material)) * transmission;
                sum += materialAnisotropicSpecular(m, normal, tangent, view,
                    ray / max(distance, 0.00001), radiance, anisotropy) * weight;
            }
        }
    }
    vec3 border = vec3(lpvShape()) * 0.5 - abs(world - cameraPosition);
    return sum * smoothstep(1.0, 5.0, min(border.x, min(border.y, border.z)));
#else
    return vec3(0.0);
#endif
}

vec3 pbrDirectGloss(SurfaceMaterial m, vec3 normal, vec3 position, vec2 uv,
                    vec2 lightmap, vec3 shadow) {
    vec3 tangent = pbrGlossTangent(normal, position, uv);
    vec3 view = safeNormalize(-position, normal);
    float anisotropy = MATERIAL_ANISOTROPY * (1.0 - m.roughness);
    vec3 solar = materialAnisotropicSpecular(m, normal, tangent, view,
        normalize(sunPosition), getSunLightColor(), anisotropy)
        + materialAnisotropicSpecular(m, normal, tangent, view,
            normalize(moonPosition), getMoonLightColor(), anisotropy);
    float sky = smoothstep(0.60, 0.96, lightmapLevel(lightmap.y));
    solar *= shadow * sky * cloudProjectedShadow(viewToAbsoluteWorld(position),
        normalize(mat3(gbufferModelViewInverse) * getLightDirView()));
    return solar + pbrLocalGloss(m, normal, tangent, position, anisotropy);
}

vec3 computePbrLighting(LabPbrMaterial pbr, vec3 normal, vec2 lightmap, vec3 shadow,
                       float occlusion, vec3 position, vec2 uv, out vec3 reflectionSource) {
    SurfaceMaterial m = pbrBrdfMaterial(pbr);
    float strength = ENABLE_MATERIAL_REFLECTIONS == 1 ? MATERIAL_REFLECTION_STRENGTH : 0.0;
    vec3 view = safeNormalize(-position, normal);
    bool reflective = max(max(m.f0.r, m.f0.g), m.f0.b) > 0.0001 && strength > 0.0;
    vec3 fraction = vec3(1.0);
    if (reflective) {
        // 偏漫反射的Glossy风格为粗糙金属保留少量基底散射。
        fraction = mix(vec3(1.0), (1.0 - 0.85 * m.metallic)
            * (1.0 - materialFresnel(m.f0, dot(normal, view))), strength);
    }
    vec3 diffuse = computeSurfaceLighting(pbr.albedo * fraction, normal, lightmap, shadow,
        occlusion * pbr.ao, position);
    vec3 environment = vec3(0.0);
    vec3 direct = vec3(0.0);
    if (reflective) {
        vec3 direction = normalize(mat3(gbufferModelViewInverse) * normal);
        environment = materialAmbientEnvironment(direction, lightmap)
            * materialEnvironmentWeight(m, dot(normal, view)) * strength;
        direct = pbrDirectGloss(m, normal, position, uv, lightmap, shadow) * strength;
    }
    vec3 emission = pbr.albedo * pbr.emission * ORE_GLOW_STRENGTH * 4.0;
    reflectionSource = diffuse + environment + emission;
    return reflectionSource + direct;
}
#endif
