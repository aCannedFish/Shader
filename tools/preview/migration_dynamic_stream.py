"""Assemble a native dynamic-triangle transport prototype on a checked full pack.

Shadow compute clears a half-float counter in C1; invocation zero of the native
geometry stage appends exact vertex/UV records to C5. Prepare reads the images
after J9's image/texture barriers and publishes one exact record into
the persistent header for inspection. Two final prepare draws clear both
scratch banks before the ordinary renderer uses C1/C5. No new attachments, host
world uploads or reflection claims are introduced by this interface prototype.
"""

import argparse
import json
from pathlib import Path
import re
import shutil


STREAM_CAPTURE = r'''
layout(rgba16f) uniform image2D colorimg1;
layout(rgba32f) uniform image2D colorimg5;

// Only invocation zero appends. Half-float increments remain exact through
// the 1024-record capacity; an over-capacity counter is never reused as an ID.
void worldCaptureDynamicStream(int material, int flags) {
    f16vec4 old = imageAtomicAdd(colorimg1, ivec2(0), f16vec4(1.0, 0.0, 0.0, 0.0));
    int index = int(old.x);
    ivec2 size = imageSize(colorimg5);
    if (index < 0 || index >= min(1024, size.x * size.y / 9)) return;
    vec4 record[9];
    record[0] = vec4(vertex[0].position, vertex[0].uv.x);
    record[1] = vec4(vertex[1].position, vertex[0].uv.y);
    record[2] = vec4(vertex[2].position, vertex[1].uv.x);
    record[3] = vec4(vertex[1].uv.y, vertex[2].uv, float(material));
    record[4] = vec4(vertex[0].colour, vertex[0].light);
    record[5] = vec4(vertex[1].colour, vertex[1].light);
    record[6] = vec4(vertex[2].colour, vertex[2].light);
    record[7] = vec4(float(frameCounter), float(blockEntityId), float(flags), 1873.0);
    record[8] = vec4(textureSize(gtexture, 0), 0.0, 1874.0);
    for (int word = 0; word < 9; word++) {
        int pixel = index * 9 + word;
        imageStore(colorimg5, ivec2(pixel % size.x, pixel / size.x), record[word]);
    }
}
'''

STREAM_IMAGES = '''
layout(rgba16f) uniform image2D colorimg1;
layout(rgba32f) uniform image2D colorimg5;
'''

STREAM_PUBLISH = r'''
    // Header aliases 400..439 are reserved only by this prototype contract.
    // Four-byte encoding preserves every float bit in the half-float atlas.
    ivec2 streamPixel = ivec2(gl_FragCoord.xy) - worldRegion(WORLD_REGION_HEADER).xy;
    if (streamPixel.y == 0 && streamPixel.x >= 400 && streamPixel.x < 440) {
        float count = imageLoad(colorimg1, ivec2(0)).x;
        int capacity = min(1024, imageSize(colorimg5).x * imageSize(colorimg5).y / 9);
        int word = streamPixel.x - 400;
        if (word == 0) result = vec4(min(count, float(capacity)), float(count > float(capacity)), 0.0, 1873.0);
        else if (word == 1) result = vec4(imageSize(colorimg1), 0.0, 0.0);
        else if (word == 2) result = vec4(imageSize(colorimg5), 0.0, 0.0);
        else if (word == 3) result = worldEncodeInt(frameCounter);
        else {
            int scalar = word - 4;
            vec4 value = count > 0.0 ? imageLoad(colorimg5, ivec2(scalar / 4, 0)) : vec4(0.0);
            result = worldEncodeUint(floatBitsToUint(value[scalar % 4]));
        }
        return;
    }
'''

RESET = '''#version 430 core
layout(local_size_x=1) in;
const ivec3 workGroups = ivec3(1);
layout(rgba16f) uniform image2D colorimg1;
void main() { imageStore(colorimg1, ivec2(0), vec4(0.0)); }
'''

SYNC = '''#version 430 core
layout(local_size_x=1) in;
const ivec3 workGroups = ivec3(1);
// J9 brackets each compute dispatch with IMAGE_ACCESS | TEXTURE_FETCH barriers.
void main() {}
'''

CLEAR_VERTEX = '''#version 330 core
in vec3 vaPosition;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
void main() { gl_Position = projectionMatrix * modelViewMatrix * vec4(vaPosition, 1.0); }
'''

CLEAR_FRAGMENT = '''#version 330 core
// Compatibility (auto-generated)
/* RENDERTARGETS: 1,5 */
layout(location=0) out vec4 clearedCounter;
layout(location=1) out vec4 clearedRecords;
void main() { clearedCounter = vec4(1.0); clearedRecords = vec4(0.0); }
'''


def build(source, target):
    """Patch a separate generated pack; the installed renderer stays untouched."""
    source = source.resolve(strict=True)
    target = target.resolve()
    if source == target or target.is_relative_to(source) or source.is_relative_to(target):
        raise ValueError("Prototype source and destination must be separate")
    if target.exists():
        raise FileExistsError("Use a fresh prototype target to preserve evidence")
    shutil.copytree(source, target)
    if re.search(r'const\s+vec4\s+colortex1ClearColor\s*=',
                 (source / "settings.glsl").read_text(encoding="utf-8")):
        raise ValueError("Prototype expects J9's default white C1 clear value")
    # J9 clears scene buffers between shadow and prepare. The scratch lifetime
    # crosses that boundary, so clear both banks explicitly after publication.
    for path in target.rglob("*"):
        if path.suffix in (".glsl", ".vsh", ".gsh", ".fsh"):
            text = path.read_text(encoding="utf-8")
            text = text.replace("const bool colortex1Clear = true;", "const bool colortex1Clear = false;")
            text = text.replace("const bool colortex5Clear = true;", "const bool colortex5Clear = false;")
            path.write_text(text, encoding="utf-8")
    for dimension in ("", "world-1", "world1"):
        folder = target / dimension
        vertex_path = folder / "shadow.vsh"
        vertex_source = vertex_path.read_text(encoding="utf-8")
        vertex_source = re.sub(r"^#version[^\n]*", "#version 450 core", vertex_source, count=1)
        vertex_path.write_text(vertex_source, encoding="utf-8")
        geometry = (folder / "shadow.gsh").read_text(encoding="utf-8")
        geometry = re.sub(r"^#version[^\n]*", "#version 450 core\n"
                          "#extension GL_NV_gpu_shader5 : require\n"
                          "#extension GL_NV_shader_atomic_fp16_vector : require", geometry, count=1)
        geometry = geometry.replace("\nvoid main() {", STREAM_CAPTURE + "\nvoid main() {", 1)
        anchor = "bool dynamic = blockEntityId > 0 || nativeMaterial > 0;"
        if anchor not in geometry:
            raise ValueError("Native dynamic classification anchor changed")
        geometry = geometry.replace(anchor, anchor + "\n    if (dynamic && gl_InvocationID == 0) "
                                    "worldCaptureDynamicStream(sourceMaterial, sourceDefinition.flags);", 1)
        (folder / "shadow.gsh").write_text(geometry, encoding="utf-8")
        fragment = (folder / "prepare.fsh").read_text(encoding="utf-8")
        fragment = re.sub(r"^#version[^\n]*", "#version 430 core", fragment, count=1)
        fragment, main_count = re.subn(r'\bvoid\s+main\s*\(\s*\)\s*\{',
            lambda match: STREAM_IMAGES + "\nvoid main() {\n" + STREAM_PUBLISH, fragment, count=1)
        if main_count != 1:
            raise ValueError("Persistent resolve entry point changed")
        consumer = folder / "prepare.fsh"
        consumer.write_text(fragment, encoding="utf-8")
        last = max(folder.glob("prepare*.fsh"), key=lambda path: int(path.stem[7:] or "0"))
        for name, code in (("shadow.csh", RESET), ("prepare.csh", SYNC)):
            path = folder / name
            if path.exists():
                raise ValueError(f"Prototype cannot replace an existing compute stage: {path}")
            path.write_text(code, encoding="utf-8")
        # Prepare1 copies the complete atlas, publishing the control record in
        # both banks before the later region-only producers begin.
        first_clear = int(last.stem[7:] or "0") + 1
        for index in (first_clear, first_clear + 1):
            (folder / f"prepare{index}.vsh").write_text(CLEAR_VERTEX, encoding="utf-8")
            (folder / f"prepare{index}.fsh").write_text(CLEAR_FRAGMENT, encoding="utf-8")
    (target / ".dynamic-stream-probe").write_text("interface prototype only\n", encoding="utf-8")
    (target / "dynamic-stream.json").write_text(json.dumps({
        "schema": 2, "capacity": 1024, "words_per_triangle": 9,
        "counter": "colortex1 image pixel 0, rgba16f, shadow through prepare",
        "records": "colortex5 image first 9216 texels, rgba32f, same lifetime",
        "persistent_readback": "header x=400..439 y=0, exact float bytes",
        "scene_attachments": 8, "host_world_uploads": False,
        "status": "unverified interface; no exact reflection surface consumer yet",
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    arguments = parser.parse_args()
    build(arguments.source, arguments.target)
