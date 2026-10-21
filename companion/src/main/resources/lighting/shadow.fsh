#version 330 core
in vec3 localPosition;
flat in int owner;
uniform vec3 uLightPosition;
uniform float uLightRadius;
uniform int uLightOwner;
uniform int uDirectional;
uniform int uTransmissionPass;
layout(location = 0) out vec4 depth;
void main() {
    if (owner == uLightOwner) {
        discard;
    }
    float value = uDirectional == 1 ? gl_FragCoord.z
        : length(localPosition - uLightPosition) / uLightRadius;
    // The voxel mesh has axis-aligned faces. Preserve the actual hit plane so
    // filtered point shadows can reproject neighbouring corner faces correctly.
    vec3 geometric = abs(cross(dFdx(localPosition), dFdy(localPosition)));
    vec3 axis = geometric.x >= geometric.y && geometric.x >= geometric.z
        ? vec3(1, 0, 0) : geometric.y >= geometric.z ? vec3(0, 1, 0) : vec3(0, 0, 1);
    float face = dot(axis, vec3(0.25, 0.5, 0.75));
    float plane = dot(localPosition - uLightPosition, axis) / uLightRadius;
    depth = uTransmissionPass == 1 ? vec4(1.0, min(value, 1.0), 1.0, 1.0)
        : vec4(min(value, 1.0), 1.0, face, plane);
}
