/* OpenGL 4.1 migration prerequisites: geometry, float MRT and ping-pong readback.
 * This fixture tests driver capabilities only; OptiFine scheduling is a separate gate.
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

static void fail(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(1);
}

static GLuint shader(GLenum type, const char *source) {
    GLuint result = glCreateShader(type);
    glShaderSource(result, 1, &source, NULL);
    glCompileShader(result);
    GLint valid;
    glGetShaderiv(result, GL_COMPILE_STATUS, &valid);
    if (!valid) {
        char log[4096];
        glGetShaderInfoLog(result, sizeof(log), NULL, log);
        fail(log);
    }
    return result;
}

static GLuint program(int geometry) {
    const char *vertex = "#version 330 core\nvoid main(){gl_Position=vec4(gl_VertexID==1?3:-1,gl_VertexID==2?3:-1,0,1);}";
    const char *middle = "#version 330 core\nlayout(triangles) in;layout(triangle_strip,max_vertices=6) out;flat out int route;"
        "void main(){for(int tile=0;tile<2;tile++){for(int i=0;i<3;i++){route=tile;vec4 p=gl_in[i].gl_Position;"
        "p.x=p.x*.5+(tile==0?-.5:.5);gl_Position=p;EmitVertex();}EndPrimitive();}}";
    const char *fragment = "#version 330 core\nflat in int route;layout(location=0) out vec4 first;layout(location=1) out vec4 second;"
        "void main(){first=route==0?vec4(1,2,3,1):vec4(2047,.125,255,1);second=vec4(route,7,.5,1);}";
    const char *accumulate = "#version 330 core\nuniform sampler2D previous;layout(location=0) out vec4 result;"
        "void main(){result=texelFetch(previous,ivec2(gl_FragCoord.xy),0)+vec4(1,0,0,0);}";
    GLuint result = glCreateProgram();
    glAttachShader(result, shader(GL_VERTEX_SHADER, vertex));
    if (geometry) glAttachShader(result, shader(GL_GEOMETRY_SHADER, middle));
    glAttachShader(result, shader(GL_FRAGMENT_SHADER, geometry ? fragment : accumulate));
    glLinkProgram(result);
    GLint valid;
    glGetProgramiv(result, GL_LINK_STATUS, &valid);
    if (!valid) {
        char log[4096];
        glGetProgramInfoLog(result, sizeof(log), NULL, log);
        fail(log);
    }
    return result;
}

static GLuint texture(GLenum format) {
    GLuint result;
    glGenTextures(1, &result);
    glBindTexture(GL_TEXTURE_2D, result);
    glTexImage2D(GL_TEXTURE_2D, 0, format, 32, 16, 0, GL_RGBA, GL_FLOAT, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return result;
}

/* Hold every contract allocation simultaneously, clear its storage and check
 * actual framebuffer completeness. The byte total includes both colour banks.
 */
static void allocateContract(const char *filename) {
    FILE *input = fopen(filename, "r");
    if (!input) fail("Cannot open allocation contract");
    GLuint textures[128], framebuffer;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    char name[128], formatName[32];
    int width, height, count = 0;
    unsigned long long bytes = 0;
    const char *fillVertex = "#version 330 core\nvoid main(){gl_Position=vec4(gl_VertexID==1?3:-1,gl_VertexID==2?3:-1,0,1);}";
    const char *fillFragment = "#version 330 core\nlayout(location=0) out vec4 result;void main(){"
        "vec2 p=gl_FragCoord.xy;result=vec4(fract(p.x*.0031),fract(p.y*.0071),fract((p.x+p.y)*.0093),1);"
        "gl_FragDepth=fract(p.x*.0031);}";
    GLuint fill = glCreateProgram();
    glAttachShader(fill, shader(GL_VERTEX_SHADER, fillVertex));
    glAttachShader(fill, shader(GL_FRAGMENT_SHADER, fillFragment));
    glLinkProgram(fill);
    GLint linked;
    glGetProgramiv(fill, GL_LINK_STATUS, &linked);
    if (!linked) fail("Cannot link nonuniform allocation writer");
    glUseProgram(fill);
    while (fscanf(input, "%127s %d %d %31s", name, &width, &height, formatName) == 4) {
        if (count >= 128 || width <= 0 || height <= 0) fail("Invalid allocation contract");
        int depth = strcmp(formatName, "DEPTH32F") == 0;
        GLenum internal = depth ? GL_DEPTH_COMPONENT32F
            : strcmp(formatName, "RGBA32F") == 0 ? GL_RGBA32F : GL_RGBA16F;
        glGenTextures(1, &textures[count]);
        glBindTexture(GL_TEXTURE_2D, textures[count]);
        glTexImage2D(GL_TEXTURE_2D, 0, internal, width, height, 0,
            depth ? GL_DEPTH_COMPONENT : GL_RGBA, GL_FLOAT, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        GLenum error = glGetError();
        if (error != GL_NO_ERROR) {
            fprintf(stderr, "Allocation %s %dx%d failed: 0x%x\n", name, width, height, error);
            exit(1);
        }
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, 0, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, depth ? GL_DEPTH_ATTACHMENT : GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D, textures[count], 0);
        glDrawBuffer(depth ? GL_NONE : GL_COLOR_ATTACHMENT0);
        glReadBuffer(depth ? GL_NONE : GL_COLOR_ATTACHMENT0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            fprintf(stderr, "Incomplete contract framebuffer: %s\n", name);
            exit(1);
        }
        glViewport(0, 0, width, height);
        glClearColor(0, 0, 0, 0);
        glClearDepth(1);
        glClear(depth ? GL_DEPTH_BUFFER_BIT : GL_COLOR_BUFFER_BIT);
        if (depth) {
            glEnable(GL_DEPTH_TEST);
            glDepthFunc(GL_ALWAYS);
            glDepthMask(GL_TRUE);
        } else {
            glDisable(GL_DEPTH_TEST);
        }
        glDrawArrays(GL_TRIANGLES, 0, 3);
        float pixel[4] = {0,0,0,0};
        glReadPixels(width-1, height-1, 1, 1, depth ? GL_DEPTH_COMPONENT : GL_RGBA, GL_FLOAT, pixel);
        float expected = (width - 0.5f) * 0.0031f;
        expected -= floorf(expected);
        if (fabsf(pixel[0] - expected) > 0.001f) fail("Nonuniform storage write/readback failed");
        bytes += (unsigned long long)width * height * (depth ? 4 : internal == GL_RGBA32F ? 16 : 8);
        count++;
    }
    fclose(input);
    glFinish();
    if (glGetError() != GL_NO_ERROR) fail("Contract clear failed");
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    printf("{\"allocation_contract_verified\":true,\"textures\":%d,\"texture_bytes\":%llu,"
        "\"nonuniform_storage_written\":true,\"process_peak_rss_bytes\":%ld,\"scope\":\"allocated/nonuniform-written storage; RSS is not GPU-only memory\"}\n",
        count, bytes, usage.ru_maxrss);
    glDeleteTextures(count, textures);
    glDeleteFramebuffers(1, &framebuffer);
}

int main(int argc, char **argv) {
    CGLPixelFormatAttribute attributes[] = {kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core, kCGLPFAAccelerated, 0};
    CGLPixelFormatObj format;
    CGLContextObj context;
    GLint count;
    if (CGLChoosePixelFormat(attributes, &format, &count) != kCGLNoError || !format) fail("No accelerated context");
    if (CGLCreateContext(format, NULL, &context) != kCGLNoError) fail("Cannot create context");
    CGLDestroyPixelFormat(format);
    CGLSetCurrentContext(context);
    GLuint array, framebuffer;
    glGenVertexArrays(1, &array);
    glBindVertexArray(array);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    GLuint geometry = program(1);
    const GLenum formats[] = {GL_RGBA16F, GL_RGBA32F};
    for (int index=0; index<2; index++) {
        GLuint textures[] = {texture(formats[index]), texture(formats[index])};
        for (int target=0; target<2; target++)
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0+target, GL_TEXTURE_2D, textures[target], 0);
        const GLenum targets[] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1};
        glDrawBuffers(2, targets);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) fail("Float MRT incomplete");
        glViewport(0, 0, 32, 16);
        glUseProgram(geometry);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        float left[4], right[4], metadata[4];
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        glReadPixels(8, 8, 1, 1, GL_RGBA, GL_FLOAT, left);
        glReadPixels(24, 8, 1, 1, GL_RGBA, GL_FLOAT, right);
        glReadBuffer(GL_COLOR_ATTACHMENT1);
        glReadPixels(24, 8, 1, 1, GL_RGBA, GL_FLOAT, metadata);
        if (left[0]!=1 || left[1]!=2 || right[0]!=2047 || right[1]!=.125 || metadata[0]!=1 || metadata[1]!=7)
            fail("Geometry partition / payload readback differs");
        glDeleteTextures(2, textures);
    }
    // Five real passes read the preceding complete texture and write the other one.
    GLuint accumulation = program(0);
    GLuint ping[] = {texture(GL_RGBA16F), texture(GL_RGBA16F)};
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, 0, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, ping[0], 0);
    glDrawBuffer(GL_COLOR_ATTACHMENT0);
    glClearColor(0,0,0,0);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(accumulation);
    glUniform1i(glGetUniformLocation(accumulation,"previous"),0);
    for(int frame=0;frame<5;frame++) {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D,ping[frame%2]);
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,ping[1-frame%2],0);
        glDrawArrays(GL_TRIANGLES,0,3);
    }
    float value[4];
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glReadPixels(4,4,1,1,GL_RGBA,GL_FLOAT,value);
    if (value[0]!=5 || glGetError()!=GL_NO_ERROR) fail("Persistent ping-pong failed");
    const GLenum limits[] = {GL_MAX_TEXTURE_SIZE,GL_MAX_COLOR_ATTACHMENTS,GL_MAX_DRAW_BUFFERS,
        GL_MAX_TEXTURE_IMAGE_UNITS,GL_MAX_GEOMETRY_TEXTURE_IMAGE_UNITS,
        GL_MAX_GEOMETRY_OUTPUT_VERTICES,GL_MAX_GEOMETRY_TOTAL_OUTPUT_COMPONENTS,GL_MAX_3D_TEXTURE_SIZE};
    const char *names[] = {"max_texture_size","color_attachments","draw_buffers","fragment_samplers",
        "geometry_samplers","geometry_output_vertices","geometry_output_components","max_3d_texture_size"};
    printf("{\"gpu\":\"%s\",\"opengl\":\"%s\",",glGetString(GL_RENDERER),glGetString(GL_VERSION));
    for(int index=0;index<8;index++) {
        GLint value;
        glGetIntegerv(limits[index],&value);
        printf("\"%s\":%d,",names[index],value);
    }
    printf("\"geometry_float_mrt_verified\":true,\"persistent_pingpong_verified\":true,\"scope\":\"CGL driver, not OptiFine scheduling\"}\n");
    if (argc == 3 && strcmp(argv[1], "--allocate") == 0) allocateContract(argv[2]);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    return 0;
}
