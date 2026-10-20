/* Offscreen macOS GPU fixture for HDR kernels. Runs supplied fragment stages
 * against an RGBA32F input, times warmed GPU work, and reads the final HDR image.
 * Full-sized ping-pong targets are deliberately filled with a bright sentinel
 * before each run to expose reads outside a reduced-resolution viewport.
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>

static void fail(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(1);
}

static char *readSource(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) fail("Cannot open shader");
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    rewind(file);
    char *data = calloc(size + 1, 1);
    if (!data || fread(data, 1, size, file) != (size_t)size) fail("Cannot read shader");
    fclose(file);
    return data;
}

static GLuint compile(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint status;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        char log[8192];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fail(log);
    }
    return shader;
}

static GLuint program(const char *path, int width, int height) {
    const char *vertex = "#version 150\nvoid main() {"
        "vec2 p = vec2((gl_VertexID == 1) ? 3.0 : -1.0,"
        "(gl_VertexID == 2) ? 3.0 : -1.0); gl_Position = vec4(p, 0, 1); }";
    // A fragment may provide a sidecar vertex stage for interpolation tests.
    char vertexPath[4096];
    snprintf(vertexPath, sizeof(vertexPath), "%s.vert", path);
    FILE *vertexFile = fopen(vertexPath, "rb");
    char *customVertex = NULL;
    if (vertexFile) {
        fclose(vertexFile);
        customVertex = readSource(vertexPath);
    }
    char *source = readSource(path);
    GLuint result = glCreateProgram();
    GLuint v = compile(GL_VERTEX_SHADER, customVertex ? customVertex : vertex);
    GLuint f = compile(GL_FRAGMENT_SHADER, source);
    glAttachShader(result, v);
    glAttachShader(result, f);
    glBindFragDataLocation(result, 0, "result");
    glBindFragDataLocation(result, 0, "result0");
    glBindFragDataLocation(result, 1, "result1");
    glLinkProgram(result);
    GLint status;
    glGetProgramiv(result, GL_LINK_STATUS, &status);
    if (!status) fail("Bloom fixture link failed");
    glUseProgram(result);
    glUniform1i(glGetUniformLocation(result, "source"), 0);
    glUniform1f(glGetUniformLocation(result, "viewWidth"), width);
    glUniform1f(glGetUniformLocation(result, "viewHeight"), height);
    glUniform1i(glGetUniformLocation(result, "colortex3"), 0);
    glUniform1i(glGetUniformLocation(result, "noisetex"), 1);
    glUniform1i(glGetUniformLocation(result, "depthtex0"), 1);
    glUniform1i(glGetUniformLocation(result, "depthtex1"), 1);
    glUniform1i(glGetUniformLocation(result, "colortex5"), 2);
    glUniform1i(glGetUniformLocation(result, "colortex4"), 2);
    // Fixed daylight for atmosphere benchmarks; unused uniforms are no-ops.
    glUniform3f(glGetUniformLocation(result, "cameraPosition"), 0, 80, 0);
    glUniform3f(glGetUniformLocation(result, "sunPosition"), 70, 35, 0);
    glUniform3f(glGetUniformLocation(result, "moonPosition"), -70, -35, 0);
    const GLfloat identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    glUniformMatrix4fv(glGetUniformLocation(result, "gbufferModelViewInverse"), 1, GL_FALSE, identity);
    glUniformMatrix4fv(glGetUniformLocation(result, "gbufferModelView"), 1, GL_FALSE, identity);
    // A fixed 90-degree perspective gives cloud tests valid forward view rays.
    const float nearPlane = 0.05f;
    const float farPlane = 256.0f;
    float aspect = (float)width / height;
    float a = -(farPlane + nearPlane) / (farPlane - nearPlane);
    float b = -2.0f * farPlane * nearPlane / (farPlane - nearPlane);
    const GLfloat projection[16] = {
        1.0f / aspect, 0, 0, 0, 0, 1, 0, 0, 0, 0, a, -1, 0, 0, b, 0
    };
    const GLfloat projectionInverse[16] = {
        aspect, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1.0f / b, 0, 0, -1, a / b
    };
    glUniformMatrix4fv(glGetUniformLocation(result, "gbufferProjection"), 1, GL_FALSE, projection);
    glUniformMatrix4fv(glGetUniformLocation(result, "gbufferProjectionInverse"), 1, GL_FALSE, projectionInverse);
    glUniform1f(glGetUniformLocation(result, "near"), nearPlane);
    glUniform1f(glGetUniformLocation(result, "far"), farPlane);
    glUniform1f(glGetUniformLocation(result, "aspectRatio"), aspect);
    glDeleteShader(v);
    glDeleteShader(f);
    free(source);
    free(customVertex);
    return result;
}

static int compare(const void *left, const void *right) {
    GLuint64 a = *(const GLuint64 *)left;
    GLuint64 b = *(const GLuint64 *)right;
    return (a > b) - (a < b);
}

/* Arguments: width height input.f32 output.f32 scale shader [scale shader ...]. */
int main(int argc, char **argv) {
    if (argc < 7 || (argc - 5) % 2 != 0) fail("Invalid bloom fixture arguments");
    int width = atoi(argv[1]);
    int height = atoi(argv[2]);
    int stages = (argc - 5) / 2;
    if (width < 1 || height < 1 || stages > 8) fail("Invalid fixture dimensions");
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj format;
    CGLContextObj context;
    GLint count;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError || !format)
        fail("Cannot create GPU pixel format");
    if (CGLCreateContext(format, NULL, &context) != kCGLNoError) fail("Cannot create GPU context");
    CGLDestroyPixelFormat(format);
    CGLSetCurrentContext(context);
    size_t length = (size_t)width * height * 4;
    float *pixels = malloc(length * sizeof(float));
    FILE *file = fopen(argv[3], "rb");
    if (!pixels || !file || fread(pixels, sizeof(float), length, file) != length)
        fail("Invalid input texture");
    fclose(file);
    const int textureCount = 3;
    GLuint textures[3], framebuffer, array, query, programs[8];
    glGenTextures(textureCount, textures);
    for (int index = 0; index < textureCount; index++) {
        glBindTexture(GL_TEXTURE_2D, textures[index]);
        glTexImage2D(GL_TEXTURE_2D, 0, index == 0 ? GL_RGBA32F : GL_RGBA16F,
            width, height, 0, GL_RGBA, GL_FLOAT, index == 0 ? pixels : NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        // Reflection fixtures can exercise the same trilinear input pyramid
        // as deferred1; ordinary HDR kernel probes retain their original setup.
        if (index == 0 && getenv("SIMPLESHADER_PROBE_INPUT_MIPS")) {
            glGenerateMipmap(GL_TEXTURE_2D);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
        }
    }
    // Secondary samplers see the immutable input, never a partially written target.
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, textures[0]);
    // No water metadata in the isolated cloud test. Keep it separate from the
    // all-sky depth/noise input so water clipping cannot truncate cloud rays.
    GLuint emptySurface;
    const GLfloat empty[4] = {0, 0, 0, 0};
    glGenTextures(1, &emptySurface);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, emptySurface);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, 1, 1, 0, GL_RGBA, GL_FLOAT, empty);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glActiveTexture(GL_TEXTURE0);
    for (int stage = 0; stage < stages; stage++) {
        programs[stage] = program(argv[6 + stage * 2], width, height);
    }
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glGenVertexArrays(1, &array);
    glBindVertexArray(array);
    glGenQueries(1, &query);
    // Optional paired pipelines share one context and alternate order. This
    // reduces frequency ramp and process-start bias in small GPU benchmarks.
    const char *splitValue = getenv("SIMPLESHADER_PROBE_SPLIT");
    int split = splitValue ? atoi(splitValue) : 0;
    if (splitValue && (split <= 0 || split >= stages)) {
        fail("Invalid paired pipeline split");
    }
    int groups = splitValue ? 2 : 1;
    GLuint64 samples[2][25];
    for (int frame = 0; frame < 30; frame++) {
        for (int pass = 0; pass < groups; pass++) {
            int group = groups == 2 ? (frame + pass) % 2 : 0;
            int first = group == 0 ? 0 : split;
            int last = groups == 2 && group == 0 ? split : stages;
            for (int index = 1; index < textureCount; index++) {
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                    GL_TEXTURE_2D, textures[index], 0);
                if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                    fail("Incomplete framebuffer");
                }
                glClearColor(100, 0, 100, 1);
                glClear(GL_COLOR_BUFFER_BIT);
            }
            glBeginQuery(GL_TIME_ELAPSED, query);
            GLuint input = textures[0];
            for (int stage = first; stage < last; stage++) {
                GLuint output = textures[1 + (stage - first) % 2];
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                    GL_TEXTURE_2D, output, 0);
                glBindTexture(GL_TEXTURE_2D, input);
                float scale = atof(argv[5 + stage * 2]);
                int w = width * scale;
                int h = height * scale;
                glViewport(0, 0, w > 0 ? w : 1, h > 0 ? h : 1);
                glUseProgram(programs[stage]);
                glDrawArrays(GL_TRIANGLES, 0, 3);
                input = output;
            }
            glEndQuery(GL_TIME_ELAPSED);
            GLuint64 elapsed;
            glGetQueryObjectui64v(query, GL_QUERY_RESULT, &elapsed);
            if (frame >= 5) {
                samples[group][frame - 5] = elapsed;
            }
        }
    }
    if (glGetError() != GL_NO_ERROR) fail("OpenGL error in HDR fixture");
    glReadPixels(0, 0, width, height, GL_RGBA, GL_FLOAT, pixels);
    file = fopen(argv[4], "wb");
    if (!file || fwrite(pixels, sizeof(float), length, file) != length) fail("Cannot write HDR result");
    fclose(file);
    for (int group = 0; group < groups; group++) {
        qsort(samples[group], 25, sizeof(GLuint64), compare);
    }
    if (groups == 1) {
        printf("{\"gpu\":\"%s\",\"median_ms\":%.6f,\"min_ms\":%.6f,\"max_ms\":%.6f}\n",
            glGetString(GL_RENDERER), samples[0][12] / 1e6,
            samples[0][0] / 1e6, samples[0][24] / 1e6);
    } else {
        printf("{\"gpu\":\"%s\",\"first_ms\":%.6f,\"second_ms\":%.6f}\n",
            glGetString(GL_RENDERER), samples[0][12] / 1e6, samples[1][12] / 1e6);
    }
    free(pixels);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    return 0;
}
