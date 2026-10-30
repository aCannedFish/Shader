in vec3 vaPosition;
void main() {
    gl_Position = vec4(vaPosition.xy * 2.0 - 1.0, 0.0, 1.0);
}
