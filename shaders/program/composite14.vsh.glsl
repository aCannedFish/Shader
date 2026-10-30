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
/* 泛光垂直过滤的全屏四边形，由加载器按泛光视口缩放。 */
void main() {
    gl_Position = (projectionMatrix * modelViewMatrix * vec4(vaPosition + modelOffset, 1.0));
}

