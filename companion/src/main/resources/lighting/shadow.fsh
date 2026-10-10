#version 330 core
in vec3 localPosition;
flat in int owner;
uniform vec3 uLightPosition;
uniform float uLightRadius;
uniform int uLightOwner;
uniform int uDirectional;
layout(location = 0) out vec4 depth;
void main() {
    if (owner == uLightOwner) {
        discard;
    }
    float value = uDirectional == 1 ? gl_FragCoord.z
        : length(localPosition - uLightPosition) / uLightRadius;
    depth = vec4(min(value, 1.0), 0.0, 0.0, 0.0);
}
