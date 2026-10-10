#version 120

// deferred1.vsh：全屏复制不透明场景，顶点由加载器提供。
void main() {
    gl_Position = ftransform();
}
