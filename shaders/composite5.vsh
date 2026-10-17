#version 120
/* 泛光垂直过滤的全屏四边形，由加载器按泛光视口缩放。 */
void main() {
    gl_Position = ftransform();
}
