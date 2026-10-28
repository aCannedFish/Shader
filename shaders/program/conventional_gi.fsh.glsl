/* Diffuse transport uses a conservative six-lobe angular stencil. Free-space
 * transport preserves energy, while material reflectance bounds feedback.
 * Direct sunlight, native skylight and independently occluded lamps seed only
 * exposed solid faces. The field therefore contains bounced light exclusively.
 */
/* RENDERTARGETS: 12 */
#include "/lib/conventional_gi.glsl"
#include "/lib/space.glsl"
#include "/lib/lighting.glsl"
layout(location=0) out vec4 result;

#if GI_QUALITY > 0
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;

// Native sky levels constrain exposure, but a single block can have lit and
// unlit faces. Test the air column outside this face before injecting sky energy.
float giSkyVisibility(ivec3 air) {
    for (int stepIndex = 0; stepIndex < COLOURED_VOLUME_SIZE / 2; stepIndex++) {
        if (!lpvInside(air)) return 1.0;
        uint voxel = lpvVoxel(air);
        if (lpvOpaque(voxel)) return 0.0;
        air.y++;
    }
    return 0.0;
}

// A surface offset avoids its own depth without extending through neighbouring
// blocks. Outside the real shadow coverage no unverified sunlight is injected.
float giSunVisibility(vec3 world, vec3 normal) {
    vec4 clip = shadowProjection * shadowModelView
        * vec4(world + normal * 0.06 - cameraPosition, 1.0);
    vec3 uv = distortShadow(clip.xyz / clip.w) * 0.5 + 0.5;
    if (any(lessThan(uv, vec3(0.001))) || any(greaterThan(uv, vec3(0.999)))) return 0.0;
    float bias = 0.04 * abs(shadowProjection[2][2]);
    return step(uv.z - bias, texture(shadowtex0, uv.xy).r);
}

// Cached per-source transmission is evaluated in the air outside this face.
// Reuse it for diffuse injection without tracing every lamp at every GI substep.
vec3 giLampIrradiance(ivec3 air, vec3 normal, vec3 receiver) {
    if (!lpvInside(air) || !lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0))) return vec3(0.0);
    ivec2 address = lpvAddress(air);
    vec3 identities = texelFetch(colortex10, address, 0).rgb;
    vec3 light = vec3(0.0);
    for (int entry = 0; entry < 3; entry++) {
        int identity = int(round(identities[entry])) - 1;
        if (identity < 0) continue;
        ivec3 source = lpvCell(identity);
        uint material = lpvVoxel(source);
        if (lpvKind(material) != LPV_EMITTER) continue;
        vec3 ray = vec3(source) + vec3(0.5, 0.72, 0.5) - receiver;
        float distance = length(ray);
        float cosine = max(dot(normal, ray / max(distance, 0.001)), 0.0);
        vec3 colour = lpvColour(material);
#if ENABLE_COLOURED_LIGHTING == 0
        colour = vec3(1.0, 0.65, 0.32);
#endif
        vec3 transmission = texelFetch(colortex11,
            address + ivec2(0, entry * textureSize(colortex8, 0).y), 0).rgb;
        light += colour * colour * lpvSourceEnergy(distance, lpvEmission(material))
            * transmission * cosine;
    }
    return light;
}
#endif

void main() {
    result = vec4(0.0);
#if GI_QUALITY > 0
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    int height = textureSize(colortex8, 0).y;
    int face = pixel.y / height;
    int index = pixel.x + (pixel.y % height) * textureSize(colortex8, 0).x;
    if (index < LPV_HEADER_SIZE) {
        vec3 origin = vec3(lpvOrigin(cameraPosition));
        vec3 part = face == 0 ? floor(origin / 1048576.0)
            : face == 1 ? mod(floor(origin / 1024.0), 1024.0) : mod(origin, 1024.0);
        result = index == 0
            ? vec4(lpvShape().x, frameCounter % 1024, frameCounter / 1024, 1973.0)
            : vec4(part, 1.0);
        return;
    }
    if (face >= 6 || index - LPV_HEADER_SIZE >= lpvShape().x * lpvShape().y * lpvShape().z) return;
    ivec3 cell = lpvCell(index - LPV_HEADER_SIZE);
    ivec3 direction = giDirection(face);
    bool valid = giHistoryValid();
    ivec3 shift = valid ? lpvOrigin(cameraPosition) - giStoredOrigin() : ivec3(0);
    uint material = lpvVoxel(cell);
    if (lpvOpaque(material)) {
        ivec3 air = cell + direction;
        if (!lpvInside(air) || lpvOpaque(lpvVoxel(air))) return;
        vec3 normal = vec3(direction);
        vec3 receiver = vec3(cell) + 0.5 + normal * 0.51;
        vec3 world = receiver + vec3(lpvOrigin(cameraPosition));
        vec3 direct = giLampIrradiance(air, normal, receiver);
#if SIMPLE_DIMENSION == 0
        vec3 sun = getSunLightColor() + getMoonLightColor();
        vec3 lightDirection = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
        float cosine = max(dot(normal, lightDirection), 0.0);
        if (cosine > 0.001) direct += sun * cosine * giSunVisibility(world, normal);
        float sky = lpvKind(material) == LPV_SOLID ? lpvEmission(material) / 15.0 : 0.0;
        direct += mix(vec3(0.48, 0.64, 1.0), vec3(0.8, 0.88, 1.0), getDayFactor())
            * sky * sky * giSkyVisibility(air) * (0.05 + 0.25 * getDayFactor()) * AMBIENT_STRENGTH
            * (0.35 + 0.65 * max(normal.y, 0.0));
#endif
        vec3 incoming = vec3(0.0);
#if GI_MULTIBOUNCE == 1
        if (valid) {
            incoming = giRead(air, face ^ 1, shift) * 0.6;
            for (int side = 0; side < 6; side++) {
                if (side / 2 != face / 2) incoming += giRead(air, side, shift) * 0.1;
            }
        }
#endif
        vec3 albedo = lpvKind(material) == LPV_SOLID ? lpvColour(material) : vec3(0.45);
        result.rgb = min(albedo, vec3(0.85)) * (direct + incoming * GI_REFLECTANCE);
    } else if (valid) {
        // A narrow cone spreads low-frequency radiance over the four adjacent
        // lobes. Weights sum to one; air cannot create or reflect energy.
        ivec3 upstream = cell - direction;
        vec3 incoming = giRead(upstream, face, shift) * 0.68;
        if (!lpvOpaque(lpvVoxel(upstream))) {
            for (int side = 0; side < 6; side++) {
                if (side / 2 != face / 2) incoming += giRead(upstream, side, shift) * 0.08;
            }
        } else {
            incoming = giRead(upstream, face, shift);
        }
        if (lpvKind(material) == LPV_GLASS) incoming *= lpvColour(material) * lpvColour(material);
        result.rgb = incoming * 0.985;
    }
    result.rgb = clamp(result.rgb, vec3(0.0), vec3(8.0));
    result.a = float(lpvKind(material));
#endif
}
