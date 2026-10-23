// Canonical centres identify blocks independently of the camera direction.
// Dynamic entity geometry is rejected by the geometry stage.
in vec3 vaPosition;
in vec4 vaColor;
in vec2 vaUV0;
in ivec2 vaUV2;
in vec3 mc_Entity;
in vec3 at_midBlock;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat4 shadowModelViewInverse;
uniform vec3 modelOffset;
out WorldVertex {
    vec3 centre;
    vec3 position;
    vec2 uv;
    vec3 colour;
    float material;
    float light;
} vertex;

void main() {
    vec4 view = modelViewMatrix * vec4(vaPosition + modelOffset, 1.0);
    vec3 relative = (shadowModelViewInverse * view).xyz;
    vertex.position = relative;
    vertex.centre = relative + at_midBlock / 64.0;
    vertex.uv = vaUV0;
    vertex.colour = vaColor.rgb;
    vertex.material = mc_Entity.x;
    ivec2 level = clamp(vaUV2 / 16, ivec2(0), ivec2(15));
    vertex.light = float(level.x + level.y * 16);
    gl_Position = projectionMatrix * view;
}
