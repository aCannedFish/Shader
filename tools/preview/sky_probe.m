/* Offscreen timing of the real sky/cloud fragment programs on the host GPU.
 * A synthetic unoccluded camera isolates these passes from Minecraft capture,
 * chunk updates and the capture client's 10 fps cap. Timer queries are used when
 * supported; synchronized wall time is reported as a separate fallback.
 */
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static char *ReadSource(const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) { perror(path); exit(1); }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    rewind(file);
    char *text = calloc((size_t)size + 1, 1);
    if (fread(text, 1, (size_t)size, file) != (size_t)size) { exit(1); }
    fclose(file);
    return text;
}

static GLuint Compile(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint status;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        char log[8192];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "%s\n", log);
        exit(1);
    }
    return shader;
}

/* Same perspective and upward camera convention as the default preview views. */
static void Configure(GLuint program, float height, float pitch) {
    glUseProgram(program);
    glUniform1f(glGetUniformLocation(program, "viewWidth"), 1920.0f);
    glUniform1f(glGetUniformLocation(program, "viewHeight"), 1080.0f);
    glUniform1f(glGetUniformLocation(program, "frameTimeCounter"), 12.0f);
    glUniform1f(glGetUniformLocation(program, "rainStrength"), 0.0f);
    glUniform1i(glGetUniformLocation(program, "isEyeInWater"), 0);
    glUniform1i(glGetUniformLocation(program, "moonPhase"), 0);
    glUniform3f(glGetUniformLocation(program, "cameraPosition"), 0.0f, height, 17.0f);
    float c = cosf(pitch);
    float s = sinf(pitch);
    GLfloat modelInverse[16] = {1,0,0,0, 0,c,-s,0, 0,s,c,0, 0,0,0,1};
    glUniformMatrix4fv(glGetUniformLocation(program, "gbufferModelViewInverse"), 1, GL_FALSE, modelInverse);
    glUniform3f(glGetUniformLocation(program, "sunPosition"), 0, 100*c, 100*s);
    glUniform3f(glGetUniformLocation(program, "moonPosition"), 0, -100*c, -100*s);
    float tangent = tanf(35.0f * (float)M_PI / 180.0f);
    float near = 0.05f;
    float far = 256.0f;
    float projectionC = -(far + near) / (far - near);
    float projectionD = -2.0f * far * near / (far - near);
    GLfloat projectionInverse[16] = {
        tangent*1920.0f/1080.0f,0,0,0, 0,tangent,0,0,
        0,0,0,1.0f/projectionD, 0,0,-1,projectionC/projectionD
    };
    glUniformMatrix4fv(glGetUniformLocation(program, "gbufferProjectionInverse"), 1, GL_FALSE, projectionInverse);
    const char *samplers[] = {"noisetex", "colortex3", "depthtex0", "colortex5"};
    for (int unit = 0; unit < 4; unit++) {
        glUniform1i(glGetUniformLocation(program, samplers[unit]), unit);
    }
}

static double ElapsedMilliseconds(uint64_t start, uint64_t end) {
    mach_timebase_info_data_t conversion;
    mach_timebase_info(&conversion);
    return (double)(end-start) * conversion.numer / conversion.denom / 1000000.0;
}

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "Usage: sky_probe atlas.rgba atmosphere.fsh low.fsh balanced.fsh high.fsh\n");
        return 2;
    }
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated, (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj format;
    CGLContextObj context;
    GLint count;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError
        || CGLCreateContext(format, NULL, &context) != kCGLNoError) { return 1; }
    CGLSetCurrentContext(context);
    const char *vertexSource = "#version 330 core\nvoid main(){"
        "vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);"
        "gl_Position=vec4(p*2.0-1.0,0.0,1.0);}";
    GLuint vertex = Compile(GL_VERTEX_SHADER, vertexSource);
    GLuint vao;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    GLuint textures[5];
    glGenTextures(5, textures);
    FILE *file = fopen(argv[1], "rb");
    if (!file) { return 1; }
    unsigned char *atlas = malloc(1024*1024*4);
    if (fread(atlas, 1, 1024*1024*4, file) != 1024*1024*4) { return 1; }
    fclose(file);
    const GLfloat sky[] = {0.12f,0.25f,0.40f,1.0f};
    const GLfloat depth[] = {1.0f};
    const GLfloat water[] = {0,0,0,0};
    for (int unit = 0; unit < 4; unit++) {
        glActiveTexture(GL_TEXTURE0 + unit);
        glBindTexture(GL_TEXTURE_2D, textures[unit]);
        if (unit == 0) {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1024, 1024, 0, GL_RGBA, GL_UNSIGNED_BYTE, atlas);
        } else {
            glTexImage2D(GL_TEXTURE_2D, 0, unit == 2 ? GL_R32F : GL_RGBA16F,
                1, 1, 0, unit == 2 ? GL_RED : GL_RGBA, GL_FLOAT,
                unit == 1 ? sky : unit == 2 ? depth : water);
        }
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    }
    glActiveTexture(GL_TEXTURE4);
    glBindTexture(GL_TEXTURE_2D, textures[4]);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, 1920, 1080, 0, GL_RGBA, GL_FLOAT, NULL);
    GLuint framebuffer;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[4], 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { return 1; }
    GLuint query;
    glGenQueries(1, &query);
    GLint timerBits = 0;
    glGetQueryiv(GL_TIME_ELAPSED, GL_QUERY_COUNTER_BITS, &timerBits);
    printf("{\"renderer\":\"%s\",\"timer_bits\":%d,\"passes\":[", glGetString(GL_RENDERER), timerBits);
    const char *names[] = {"atmosphere", "low", "balanced", "high"};
    for (int pass = 0; pass < 4; pass++) {
        char *source = ReadSource(argv[pass+2]);
        GLuint fragment = Compile(GL_FRAGMENT_SHADER, source);
        GLuint program = glCreateProgram();
        glAttachShader(program, vertex);
        glAttachShader(program, fragment);
        glLinkProgram(program);
        GLint linked;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) { fprintf(stderr, "Link failed\n"); return 1; }
        glViewport(0, 0, pass == 0 ? 240 : 960, pass == 0 ? 135 : 540);
        int views = pass == 0 ? 1 : 2;
        for (int view = 0; view < views; view++) {
            Configure(program, view == 0 ? 160.0f : 332.8f, 20.0f*(float)M_PI/180.0f);
            for (int warmup = 0; warmup < 5; warmup++) { glDrawArrays(GL_TRIANGLES, 0, 3); }
            glFinish();
            double gpu = 0.0;
            double wall = 0.0;
            for (int repeat = 0; repeat < 20; repeat++) {
                uint64_t start = mach_absolute_time();
                if (timerBits) { glBeginQuery(GL_TIME_ELAPSED, query); }
                glDrawArrays(GL_TRIANGLES, 0, 3);
                if (timerBits) { glEndQuery(GL_TIME_ELAPSED); }
                glFinish();
                wall += ElapsedMilliseconds(start, mach_absolute_time());
                if (timerBits) {
                    GLuint64 nanoseconds;
                    glGetQueryObjectui64v(query, GL_QUERY_RESULT, &nanoseconds);
                    gpu += nanoseconds / 1000000.0;
                }
            }
            GLenum error = glGetError();
            if (error != GL_NO_ERROR) { fprintf(stderr, "GL error %u\n", error); return 1; }
            printf("%s{\"quality\":\"%s\",\"view\":\"%s\",\"gpu_ms\":%.4f,\"wall_ms\":%.4f}",
                pass == 0 && view == 0 ? "" : ",", names[pass], view == 0 ? "below" : "inside", gpu/20.0, wall/20.0);
        }
        glDeleteProgram(program);
        glDeleteShader(fragment);
        free(source);
    }
    printf("]}\n");
    free(atlas);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    CGLDestroyPixelFormat(format);
    return 0;
}
