/*
 * Execute the project's wind functions through transform feedback on OpenGL 4.1.
 * Synthetic roots, shared leaf vertices and a double-plant seam test invariants;
 * the visual/motion checks separately use captured Minecraft geometry.
 */
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

/* Each sample supplies a world-space point and the real block-center convention. */
typedef struct {
    GLfloat position[3];
    GLfloat center[3];
    GLfloat material;
    GLfloat normal[3];
} WindVertex;

static const WindVertex kVertices[] = {
    {{0.5,81,0.5}, {0.5,81.5,0.5}, 201, {0.7071068,0,0.7071068}},
    {{0.5,82,0.5}, {0.5,81.5,0.5}, 201, {0.7071068,0,0.7071068}},
    {{3.5,82,0.5}, {3.5,81.5,0.5}, 202, {0.7071068,0,0.7071068}},
    {{3.5,82,0.5}, {3.5,82.5,0.5}, 203, {0.7071068,0,0.7071068}},
    {{3.5,81,0.5}, {3.5,81.5,0.5}, 202, {0.7071068,0,0.7071068}},
    {{3.5,83,0.5}, {3.5,82.5,0.5}, 203, {0.7071068,0,0.7071068}},
    {{6.5,81,0.5}, {6.5,81.5,0.5}, 204, {0.7071068,0,0.7071068}},
    {{6.5,81.2,0.5}, {6.5,81.5,0.5}, 204, {0.7071068,0,0.7071068}},
    {{6.5,81.9,0.5}, {6.5,81.5,0.5}, 204, {0.7071068,0,0.7071068}},
    {{9,85,2}, {8.5,84.5,2.5}, 200, {0,1,0}},
    {{9,85,2}, {9.5,85.5,2.5}, 200, {0,1,0}},
    {{10,86,4}, {10.5,86.5,4.5}, 200, {0,1,0}},
    {{12,81,1}, {12.5,81.5,1.5}, 0, {0,1,0}},
    {{14,81,1}, {14.5,81.5,1.5}, 100, {0,1,0}},
};

/* Read generated GLSL without introducing a second copy of the wind algorithm. */
static char *ReadSource(const char *path) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        perror(path);
        exit(1);
    }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    rewind(file);
    char *text = calloc((size_t)size + 1, 1);
    if (text == NULL || fread(text, 1, (size_t)size, file) != (size_t)size) {
        exit(1);
    }
    fclose(file);
    return text;
}

static GLuint CompileVertex(const char *source) {
    GLuint shader = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint status = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        char log[4096];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "Wind probe compilation failed: %s\n", log);
        exit(1);
    }
    return shader;
}

/* Independent camera rotations test world recovery in main and shadow spaces. */
static void Rotation(GLfloat *matrix, float angle, int shadow) {
    for (int i = 0; i < 16; i++) {
        matrix[i] = 0.0f;
    }
    matrix[15] = 1.0f;
    float c = cosf(angle);
    float s = sinf(angle);
    if (shadow) {
        matrix[0] = 1.0f;
        matrix[5] = c;
        matrix[6] = s;
        matrix[9] = -s;
        matrix[10] = c;
    } else {
        matrix[0] = c;
        matrix[2] = -s;
        matrix[5] = 1.0f;
        matrix[8] = s;
        matrix[10] = c;
    }
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: wind_probe generated.vsh feedback.bin\n");
        return 2;
    }
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint formats = 0;
    if (CGLChoosePixelFormat(attributes, &format, &formats) != kCGLNoError
        || CGLCreateContext(format, NULL, &context) != kCGLNoError) {
        fprintf(stderr, "Cannot create wind probe context\n");
        return 1;
    }
    CGLSetCurrentContext(context);
    char *source = ReadSource(argv[1]);
    GLuint vertex = CompileVertex(source);
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glBindAttribLocation(program, 0, "probePosition");
    glBindAttribLocation(program, 1, "probeCenter");
    glBindAttribLocation(program, 2, "probeMaterial");
    glBindAttribLocation(program, 3, "probeNormal");
    const char *varyings[] = {"windOffset", "windNormal", "windRoot", "shadowOffset"};
    glTransformFeedbackVaryings(program, 4, varyings, GL_INTERLEAVED_ATTRIBS);
    glLinkProgram(program);
    GLint status = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (!status) {
        char log[4096];
        glGetProgramInfoLog(program, sizeof(log), NULL, log);
        fprintf(stderr, "Wind probe link failed: %s\n", log);
        return 1;
    }
    // An explicit target keeps drawing legal without a window drawable.
    GLuint framebuffer = 0;
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    glViewport(0, 0, 1, 1);
    glUseProgram(program);
    glUniform3f(glGetUniformLocation(program, "cameraPosition"), 5.5f, 86.0f, 60.0f);
    glUniform1f(glGetUniformLocation(program, "rainStrength"), 0.0f);
    GLfloat matrix[16];
    const char *names[] = {"gbufferModelView", "gbufferModelViewInverse",
                           "shadowModelView", "shadowModelViewInverse"};
    for (int i = 0; i < 4; i++) {
        float angle = i < 2 ? 0.57f : -0.96f;
        Rotation(matrix, i % 2 == 0 ? angle : -angle, i >= 2);
        glUniformMatrix4fv(glGetUniformLocation(program, names[i]), 1, GL_FALSE, matrix);
    }

    GLuint array = 0;
    GLuint input = 0;
    GLuint feedback = 0;
    glGenVertexArrays(1, &array);
    glBindVertexArray(array);
    glGenBuffers(1, &input);
    glBindBuffer(GL_ARRAY_BUFFER, input);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kVertices), kVertices, GL_STATIC_DRAW);
    const size_t offsets[] = {offsetof(WindVertex, position), offsetof(WindVertex, center),
                              offsetof(WindVertex, material), offsetof(WindVertex, normal)};
    for (int i = 0; i < 4; i++) {
        glEnableVertexAttribArray(i);
        glVertexAttribPointer(i, i == 2 ? 1 : 3, GL_FLOAT, GL_FALSE,
                              sizeof(WindVertex), (const void *)offsets[i]);
    }
    const GLint count = sizeof(kVertices) / sizeof(kVertices[0]);
    const GLsizeiptr bytes = count * 12 * sizeof(GLfloat);
    glGenBuffers(1, &feedback);
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, feedback);
    glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, bytes, NULL, GL_STREAM_READ);
    glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, feedback);
    glEnable(GL_RASTERIZER_DISCARD);
    FILE *output = fopen(argv[2], "wb");
    if (output == NULL) {
        perror(argv[2]);
        return 1;
    }
    const int frames = 2;
    fwrite(&count, sizeof(count), 1, output);
    fwrite(&frames, sizeof(frames), 1, output);
    GLfloat *values = malloc((size_t)bytes);
    for (int frame = 0; frame < frames; frame++) {
        glUniform1f(glGetUniformLocation(program, "frameTimeCounter"), 12.0f + frame * 4.0f);
        glBeginTransformFeedback(GL_POINTS);
        glDrawArrays(GL_POINTS, 0, count);
        glEndTransformFeedback();
        glFinish();
        glGetBufferSubData(GL_TRANSFORM_FEEDBACK_BUFFER, 0, bytes, values);
        fwrite(values, 1, (size_t)bytes, output);
    }
    fclose(output);
    free(values);
    free(source);
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        fprintf(stderr, "Wind probe OpenGL error: 0x%x\n", error);
        return 1;
    }
    printf("Wind feedback: %d samples on %s\n", count, glGetString(GL_RENDERER));
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    CGLDestroyPixelFormat(format);
    return 0;
}
