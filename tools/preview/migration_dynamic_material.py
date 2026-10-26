"""Persist native triangle records and their actual texture pixels on the GPU.

This isolated prototype extends the verified stream transport. It borrows the
unused planar capture and reflection-work regions, checking those aliases
before use. The currently installed renderer is not modified by this builder.
"""

import argparse
import json
from pathlib import Path
import re

from . import migration_dynamic_stream as stream


CAPTURE = r'''
layout(rgba16f) uniform image2D colorimg1;
layout(rgba32f) uniform image2D colorimg5;
layout(rgba32f) uniform image2D shadowcolorimg0;
uniform float alphaTestRef;

// Each allocation owns whole 256-texel units. Valid offsets stay below the
// half-float exact-integer range; exhausted allocations never write the pool.
void worldCaptureDynamicStream(int material, int flags) {
    int index = int(imageAtomicAdd(colorimg1, ivec2(0), f16vec4(1.0, 0.0, 0.0, 0.0)).x);
    ivec2 size = imageSize(colorimg5);
    if (index < 0 || index >= min(1024, size.x * size.y / 13)) return;
    ivec2 nativeSize = textureSize(gtexture, 0);
    vec2 lowUv = min(vertex[0].uv, min(vertex[1].uv, vertex[2].uv));
    vec2 highUv = max(vertex[0].uv, max(vertex[1].uv, vertex[2].uv));
    bool finiteUv = !any(isnan(lowUv)) && !any(isinf(lowUv))
        && !any(isnan(highUv)) && !any(isinf(highUv));
    ivec2 first = finiteUv ? ivec2(floor(lowUv * vec2(nativeSize))) - 1 : ivec2(0);
    ivec2 extent = finiteUv ? ivec2(ceil(highUv * vec2(nativeSize))) + 1 - first : ivec2(0);
    bool valid = finiteUv && all(greaterThan(nativeSize, ivec2(0)))
        && all(greaterThan(extent, ivec2(0))) && all(lessThanEqual(extent, ivec2(66)));
    int base = -1;
    vec4 referenceColour = vec4(0.0);
    ivec2 referencePixel = extent / 2;
    if (valid) {
        int units = (extent.x * extent.y + 255) / 256;
        int firstUnit = int(imageAtomicAdd(colorimg1, ivec2(1, 0),
            f16vec4(float(units), 0.0, 0.0, 0.0)).x);
        int available = WORLD_CAPTURE_PLANAR.z * WORLD_CAPTURE_PLANAR.w / 256;
        valid = firstUnit >= 0 && firstUnit + units <= min(available, 2048);
        base = firstUnit * 256;
    }
    if (valid) {
        for (int pixel = 0; pixel < 4356; pixel++) {
            if (pixel >= extent.x * extent.y) break;
            ivec2 offset = ivec2(pixel % extent.x, pixel / extent.x);
            ivec2 nativePixel = clamp(first + offset, ivec2(0), nativeSize - 1);
            vec4 colour = texelFetch(gtexture, nativePixel, 0);
            int address = base + pixel;
            ivec2 target = WORLD_CAPTURE_PLANAR.xy
                + ivec2(address % WORLD_CAPTURE_PLANAR.z, address / WORLD_CAPTURE_PLANAR.z);
            imageStore(shadowcolorimg0, target, colour);
            if (all(equal(offset, referencePixel))) referenceColour = colour;
        }
    } else {
        imageAtomicAdd(colorimg1, ivec2(2, 0), f16vec4(1.0, 0.0, 0.0, 0.0));
    }
    vec4 record[13];
    record[0] = vec4(vertex[0].position, vertex[0].uv.x);
    record[1] = vec4(vertex[1].position, vertex[0].uv.y);
    record[2] = vec4(vertex[2].position, vertex[1].uv.x);
    record[3] = vec4(vertex[1].uv.y, vertex[2].uv, float(material));
    record[4] = vec4(vertex[0].colour, vertex[0].light);
    record[5] = vec4(vertex[1].colour, vertex[1].light);
    record[6] = vec4(vertex[2].colour, vertex[2].light);
    record[7] = vec4(float(frameCounter), float(blockEntityId), float(flags), 1873.0);
    record[8] = vec4(nativeSize, alphaTestRef, 1874.0);
    record[9] = vec4(float(base), first, 1875.0);
    record[10] = vec4(extent, float(valid), 1880.0);
    record[11] = referenceColour;
    record[12] = vec4(referencePixel, 0.0, 1881.0);
    for (int word = 0; word < 13; word++) {
        int pixel = index * 13 + word;
        imageStore(colorimg5, ivec2(pixel % size.x, pixel / size.x), record[word]);
    }
}
'''

PUBLISH = r'''
    ivec2 dynamicPixel = ivec2(gl_FragCoord.xy);
    int dynamicCapacity = min(1024, imageSize(colorimg5).x * imageSize(colorimg5).y / 13);
    int dynamicCount = clamp(int(imageLoad(colorimg1, ivec2(0)).x), 0, dynamicCapacity);
    if (worldInsideRectangle(dynamicPixel, WORLD_DYNAMIC_RECORDS)) {
        ivec2 local = dynamicPixel - WORLD_DYNAMIC_RECORDS.xy;
        int scalar = local.y * WORLD_DYNAMIC_RECORDS.z + local.x;
        if (scalar < dynamicCount * 52) {
            int address = scalar / 4;
            ivec2 size = imageSize(colorimg5);
            vec4 value = imageLoad(colorimg5, ivec2(address % size.x, address / size.x));
            result = worldEncodeUint(floatBitsToUint(value[scalar % 4]));
        } else result = vec4(0.0);
        return;
    }
    if (worldInsideRectangle(dynamicPixel, WORLD_DYNAMIC_COLOURS)) {
        ivec2 local = dynamicPixel - WORLD_DYNAMIC_COLOURS.xy;
        int address = local.y * WORLD_DYNAMIC_COLOURS.z + local.x;
        result = address < WORLD_CAPTURE_PLANAR.z * WORLD_CAPTURE_PLANAR.w
            ? texelFetch(shadowcolor0, WORLD_CAPTURE_PLANAR.xy
                + ivec2(address % WORLD_CAPTURE_PLANAR.z, address / WORLD_CAPTURE_PLANAR.z), 0)
            : vec4(0.0);
        return;
    }
    ivec2 streamPixel = dynamicPixel - worldRegion(WORLD_REGION_HEADER).xy;
    if (streamPixel.y == 0 && streamPixel.x >= 400 && streamPixel.x < 456) {
        float count = imageLoad(colorimg1, ivec2(0)).x;
        float invalid = imageLoad(colorimg1, ivec2(2, 0)).x;
        int capacity = min(1024, imageSize(colorimg5).x * imageSize(colorimg5).y / 13);
        int word = streamPixel.x - 400;
        if (word == 0) result = vec4(min(count, float(capacity)),
            float(count > float(capacity) || invalid > 0.0), invalid, 1873.0);
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


def rectangle(region):
    """Emit the exact allocation already present in the checked layout."""
    return "ivec4(" + ", ".join(str(region[key]) for key in ("x", "y", "width", "height")) + ")"


def build(source, target):
    """Extend the stream without reallocating or taking an active renderer field."""
    source = source.resolve(strict=True)
    layout = json.loads((source / "world-layout.json").read_text(encoding="utf-8"))
    regions = layout["persistent"]["regions"]
    records = regions["reflection_work_meta"]
    colours = regions["reflection_work"]
    raw = layout["capture"]["regions"]["capture_planar"]
    if records["width"] * records["height"] < 1024 * 52:
        raise ValueError("Reserved record region is too small")
    if colours["width"] * colours["height"] < raw["width"] * raw["height"]:
        raise ValueError("Reserved colour region is too small")
    for path in source.rglob("*"):
        if path.suffix not in (".fsh", ".gsh", ".vsh"):
            continue
        code = path.read_text(encoding="utf-8")
        if re.search(r'worldRegion\(\s*WORLD_REGION_REFLECTION_WORK(?:_META)?\s*\)', code):
            raise ValueError(f"Prototype alias is already consumed: {path}")
        if re.search(r'^\s*#define\s+WORLD_PLANAR_REFLECTION\b', code, re.M):
            raise ValueError("Planar capture is active")
    stream.build(source, target)
    constants = ("\nconst ivec4 WORLD_DYNAMIC_RECORDS = " + rectangle(records) + ";\n"
                 "const ivec4 WORLD_DYNAMIC_COLOURS = " + rectangle(colours) + ";\n")
    for dimension in ("", "world-1", "world1"):
        folder = target / dimension
        geometry = (folder / "shadow.gsh").read_text(encoding="utf-8")
        if geometry.count(stream.STREAM_CAPTURE) != 1:
            raise ValueError("Stream capture insertion point changed")
        geometry = geometry.replace(stream.STREAM_CAPTURE, CAPTURE)
        (folder / "shadow.gsh").write_text(geometry, encoding="utf-8")
        fragment = (folder / "shadow.fsh").read_text(encoding="utf-8")
        fragment = fragment.replace("void main() {", "void main() {\n"
            "    if (worldInsideRectangle(ivec2(gl_FragCoord.xy), WORLD_CAPTURE_PLANAR)) discard;", 1)
        (folder / "shadow.fsh").write_text(fragment, encoding="utf-8")
        resolve = (folder / "prepare.fsh").read_text(encoding="utf-8")
        resolve = resolve.replace(stream.STREAM_IMAGES, stream.STREAM_IMAGES + constants)
        resolve = resolve.replace(stream.STREAM_PUBLISH, PUBLISH)
        (folder / "prepare.fsh").write_text(resolve, encoding="utf-8")
        reset = stream.RESET.replace("imageStore(colorimg1, ivec2(0), vec4(0.0));",
            "for (int i = 0; i < 3; i++) imageStore(colorimg1, ivec2(i, 0), vec4(0.0));")
        (folder / "shadow.csh").write_text(reset, encoding="utf-8")
    contract = json.loads((target / "dynamic-stream.json").read_text(encoding="utf-8"))
    contract.update({"schema": 3, "words_per_triangle": 13, "material_cache": True,
                     "records": "colortex5 first 13312 texels, rgba32f, shadow through prepare",
                     "record_region": records, "colour_region": colours,
                     "raw_colour_region": raw,
                     "persistent_readback": "header x=400..455 and full record/colour regions",
                     "status": "unverified persistent geometry/material cache; reflection query pending"})
    (target / "dynamic-stream.json").write_text(json.dumps(contract, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    arguments = parser.parse_args()
    build(arguments.source, arguments.target)
