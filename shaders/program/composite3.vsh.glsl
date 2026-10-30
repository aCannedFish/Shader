#define SIMPLE_VARYING out

in vec3 vaPosition;
in vec4 vaColor;
in vec3 vaNormal;
in vec2 vaUV0;
in ivec2 vaUV2;
uniform vec3 modelOffset;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat3 normalMatrix;
void main() {
    gl_Position = vec4(vaPosition.xy * 2.0 - 1.0, 0.0, 1.0);
}
