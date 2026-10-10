/*
 * Minimal macOS OpenGL capture fixture.
 * A Cocoa drawable renders one triangle and writes its original pixels.
 * The trace can then be replayed after this process exits, with either shader
 * replaced, to verify the GPU backend independently of Minecraft.
 */
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>

static const int kWidth = 320;
static const int kHeight = 180;

static const char *kVertexSource =
    "#version 150\n"
    "in vec2 position;\n"
    "void main() { gl_Position = vec4(position, 0.0, 1.0); }\n";

static const char *kFragmentSource =
    "#version 150\n"
    "out vec4 color;\n"
    "void main() { color = vec4(0.2, 0.7, 0.4, 1.0); }\n";

/* Compile a shader and fail explicitly rather than drawing an invalid program. */
static GLuint CompileShader(GLenum stage, const char *source) {
    GLuint shader = glCreateShader(stage);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[4096];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "Shader compilation failed: %s\n", log);
        exit(1);
    }
    return shader;
}

/* Save top-down RGB pixels so the original image is directly comparable. */
static void SavePixels(const char *path) {
    unsigned char *pixels = malloc(kWidth * kHeight * 3);
    if (pixels == NULL) {
        exit(1);
    }
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glReadPixels(0, 0, kWidth, kHeight, GL_RGB, GL_UNSIGNED_BYTE, pixels);
    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        perror(path);
        free(pixels);
        exit(1);
    }
    fprintf(file, "P6\n%d %d\n255\n", kWidth, kHeight);
    for (int row = kHeight - 1; row >= 0; row--) {
        fwrite(pixels + row * kWidth * 3, 1, kWidth * 3, file);
    }
    fclose(file);
    free(pixels);
}

/* Create the same Core Profile family used by the local Minecraft instance. */
int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: gl_probe original.ppm\n");
        return 2;
    }
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSOpenGLPixelFormatAttribute attributes[] = {
            NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion4_1Core,
            NSOpenGLPFAColorSize, 24,
            NSOpenGLPFAAlphaSize, 8,
            NSOpenGLPFADepthSize, 24,
            NSOpenGLPFADoubleBuffer,
            NSOpenGLPFAAccelerated,
            0
        };
        NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc]
            initWithAttributes:attributes];
        if (format == nil) {
            fprintf(stderr, "Cannot create OpenGL 4.1 Core drawable.\n");
            return 1;
        }
        NSRect rectangle = NSMakeRect(0, 0, kWidth, kHeight);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:rectangle
            styleMask:NSWindowStyleMaskTitled
            backing:NSBackingStoreBuffered
            defer:NO];
        NSOpenGLView *view = [[NSOpenGLView alloc]
            initWithFrame:rectangle pixelFormat:format];
        [window setContentView:view];
        // Realize the drawable before accessing its default framebuffer.
        [window orderFront:nil];
        [window display];
        NSOpenGLContext *context = [view openGLContext];
        [context makeCurrentContext];
        [context update];
        while (glGetError() != GL_NO_ERROR) {
            // Ignore Cocoa's initial drawable setup errors; check our own work.
        }
        printf("GPU: %s\nOpenGL: %s\n", glGetString(GL_RENDERER),
               glGetString(GL_VERSION));

        // Render to an explicit target so display visibility does not affect it.
        GLuint colorTexture = 0;
        GLuint framebuffer = 0;
        glGenTextures(1, &colorTexture);
        glBindTexture(GL_TEXTURE_2D, colorTexture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kWidth, kHeight, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, colorTexture, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            fprintf(stderr, "Offscreen framebuffer is incomplete.\n");
            return 1;
        }

        GLuint vertex = CompileShader(GL_VERTEX_SHADER, kVertexSource);
        GLuint fragment = CompileShader(GL_FRAGMENT_SHADER, kFragmentSource);
        GLuint program = glCreateProgram();
        glAttachShader(program, vertex);
        glAttachShader(program, fragment);
        glBindAttribLocation(program, 0, "position");
        glLinkProgram(program);
        GLint linked = GL_FALSE;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            fprintf(stderr, "Shader program link failed.\n");
            return 1;
        }

        const GLfloat vertices[] = {
            -0.8f, -0.7f,
             0.8f, -0.7f,
             0.0f,  0.8f
        };
        GLuint array = 0;
        GLuint buffer = 0;
        glGenVertexArrays(1, &array);
        glBindVertexArray(array);
        glGenBuffers(1, &buffer);
        glBindBuffer(GL_ARRAY_BUFFER, buffer);
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
        glViewport(0, 0, kWidth, kHeight);
        glClearColor(0.04f, 0.06f, 0.1f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glUseProgram(program);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();
        SavePixels(argv[1]);
        [context flushBuffer];

        GLenum error = glGetError();
        if (error != GL_NO_ERROR) {
            fprintf(stderr, "OpenGL error: 0x%x\n", error);
            return 1;
        }
        [NSOpenGLContext clearCurrentContext];
        return 0;
    }
}
