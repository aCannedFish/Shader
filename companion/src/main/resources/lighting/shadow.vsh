#version 330 core
layout(location = 0) in vec4 positionOwner;
uniform mat4 uLightMatrix;
out vec3 localPosition;
flat out int owner;
void main() {
    localPosition = positionOwner.xyz;
    owner = int(positionOwner.w + 0.5);
    gl_Position = uLightMatrix * vec4(localPosition, 1.0);
}
