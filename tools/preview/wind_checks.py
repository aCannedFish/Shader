"""GPU invariants and real Minecraft frame comparisons for foliage wind."""

import json
import math
import shutil
import struct
import subprocess

from PIL import Image, ImageChops, ImageStat

from .replay import render
from .source import expand

SCENES = ("vegetation", "vegetation_motion", "vegetation_roots", "vegetation_shadows")


def wind_probe(root, work):
    """Run the actual GLSL library on the GPU; read roots/seams through feedback."""
    work.mkdir(parents=True, exist_ok=True)
    source = "#version 150\n" + expand(root / "shaders/lib/foliage_wind.glsl", root / "shaders")
    source += """
in vec3 probePosition;
in vec3 probeCenter;
in float probeMaterial;
in vec3 probeNormal;
out vec3 windOffset;
out vec3 windNormal;
out vec3 windRoot;
out vec3 shadowOffset;
void main() {
    vec3 playerPosition = probePosition - cameraPosition;
    vec3 viewPosition = (gbufferModelView * vec4(playerPosition, 1.0)).xyz;
    vec3 mainWorld = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz + cameraPosition;
    vec3 shadowView = (shadowModelView * vec4(playerPosition, 1.0)).xyz;
    vec3 shadowWorld = (shadowModelViewInverse * vec4(shadowView, 1.0)).xyz + cameraPosition;
    vec3 midOffset = probeCenter - probePosition;
    windRoot = foliageRoot(mainWorld + midOffset, probeMaterial);
    vec3 shadowRoot = foliageRoot(shadowWorld + midOffset, probeMaterial);
    windOffset = foliageWindOffset(mainWorld, windRoot, probeMaterial);
    windNormal = foliageWindNormal(mainWorld, windRoot, probeMaterial, probeNormal);
    shadowOffset = foliageWindOffset(shadowWorld, shadowRoot, probeMaterial);
    gl_Position = vec4(probePosition, 1.0);
}
"""
    shader = work / "wind-probe.vsh"
    shader.write_text(source)
    binary = work / "wind_probe"
    subprocess.run(["clang", "-Wno-deprecated-declarations", str(root / "tools/preview/wind_probe.m"),
                    "-framework", "OpenGL", "-o", str(binary)], check=True)
    output = work / "feedback.bin"
    subprocess.run([str(binary), str(shader), str(output)], check=True)
    data = output.read_bytes()
    count, frames = struct.unpack_from("=ii", data)
    values = struct.unpack_from("=" + "f" * (count * frames * 12), data, 8)
    rows = [[values[(frame * count + vertex) * 12:(frame * count + vertex + 1) * 12]
             for vertex in range(count)] for frame in range(frames)]

    def distance(first, second):
        return math.sqrt(sum((a - b) ** 2 for a, b in zip(first, second)))

    zero = (0.0, 0.0, 0.0)
    roots = max(distance(frame[index][:3], zero) for frame in rows for index in (0, 4, 6))
    seam = max(distance(frame[2][:3], frame[3][:3]) for frame in rows)
    leaves = max(distance(frame[9][:3], frame[10][:3]) for frame in rows)
    solid = max(distance(frame[index][:3], zero) for frame in rows for index in (12, 13))
    shadow = max(distance(row[:3], row[9:12]) for frame in rows for row in frame)
    normals = max(abs(distance(row[3:6], zero) - 1.0) for frame in rows for row in frame)
    motion = distance(rows[0][1][:3], rows[1][1][:3])
    if max(roots, seam, leaves, solid) > 1.0e-5 or shadow > 2.0e-4 or normals > 2.0e-5:
        raise RuntimeError("GPU wind root/seam/normal/main-shadow invariants failed")
    if motion <= 0.01 or not all(distance(frame[7][:3], zero) < distance(frame[8][:3], zero)
                                 for frame in rows):
        raise RuntimeError("GPU wind motion/growth scaling is ineffective")
    return {"root_displacement": roots, "double_plant_seam_error": seam,
            "shared_leaf_vertex_error": leaves, "solid_displacement": solid,
            "main_shadow_displacement_error": shadow, "normal_length_error": normals,
            "tip_motion": motion}


def verify_wind(root, runtime, converter):
    """Check both deformation invariants and captured animated geometry/shadows."""
    work = root / ".preview/wind-verification"
    result = wind_probe(root, work / "probe")
    baseline = work / "baseline"
    render(root, runtime, converter, names=SCENES, output=baseline)

    def variant(name, edit):
        shaders = work / (name + "-shaders")
        shutil.copytree(root / "shaders", shaders, dirs_exist_ok=True)
        filename, before, after = edit
        path = shaders / filename
        text = path.read_text()
        if before not in text:
            raise RuntimeError(f"Wind verification edit no longer applies: {filename}")
        path.write_text(text.replace(before, after, 1))
        destination = work / name
        render(root, runtime, converter, names=SCENES, shader_root=shaders, output=destination)
        return destination

    disabled = variant("off", ("settings.glsl", "#define ENABLE_FOLIAGE_WIND 1",
                                "#define ENABLE_FOLIAGE_WIND 0"))
    frozen = variant("frozen", ("lib/foliage_wind.glsl", "return frameTimeCounter * WIND_SPEED;",
                                "return 12.0 * WIND_SPEED;"))
    mismatched = variant("static-shadow", ("shadow.vsh",
        "position += foliageWindOffset(worldPosition, root, mc_Entity.x);",
        "position += vec3(0.0);"))

    def image(directory, scene):
        return Image.open(directory / (scene + ".png")).convert("RGB")

    def error(first, second):
        delta = ImageChops.difference(first, second)
        return sum(ImageStat.Stat(delta).mean) / 3.0

    # Middle/lower region contains the plant silhouettes and ground, excluding moving sky.
    region = (0, 300, 1920, 1050)
    motion = error(image(baseline, SCENES[0]).crop(region), image(baseline, SCENES[1]).crop(region))
    still = error(image(frozen, SCENES[0]).crop(region), image(frozen, SCENES[1]).crop(region))
    changes = {scene: error(image(baseline, scene), image(disabled, scene)) for scene in SCENES}
    shadow_change = error(image(baseline, "vegetation_shadows"),
                          image(mismatched, "vegetation_shadows"))
    if motion <= still + 0.2 or min(changes.values()) <= 0.15 or shadow_change <= 0.05:
        raise RuntimeError(f"Captured wind/shadow output is ineffective: motion={motion}, still={still}, "
                           f"changes={changes}, shadow={shadow_change}")
    result.update({"frame_motion_mean_change": motion, "frozen_mean_change": still,
                   "wind_toggle_mean_changes": changes, "shadow_adaptation_mean_change": shadow_change})
    (work / "verification.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), flush=True)
    return result
