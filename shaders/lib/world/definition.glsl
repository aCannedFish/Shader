#ifndef SIMPLE_WORLD_DEFINITION_GLSL
#define SIMPLE_WORLD_DEFINITION_GLSL

// Immutable metadata and observed geometry remain separate. Emission RGB is a
// hue (zero for inactive emitters); its independent native level supplies energy.
struct WorldDefinition {
    int firstBox;
    int boxCount;
    int legacy;
    vec3 emission;
    int emissionLevel;
    int alphaType;
    vec3 absorption;
    int flags;
};

WorldDefinition worldDecodeDefinition(vec4 geometry, vec4 emission, vec4 optical) {
    ivec4 index = ivec4(round(geometry));
    int emissionBits = int(round(emission.w));
    return WorldDefinition(index.x + (index.y & 31) * 2048, index.z, index.w,
        max(emission.rgb, vec3(0.0)), emissionBits % 16, emissionBits / 16,
        max(optical.rgb, vec3(0.0)), (int(round(optical.w)) & 2047) | ((index.y >> 5) << 11));
}

bool worldDefinitionFlag(WorldDefinition definition, int flag) {
    return (definition.flags & flag) != 0;
}
#endif
