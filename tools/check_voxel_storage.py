#!/usr/bin/env python3
"""Check that a conventional pack keeps voxel images outside raster targets.

The contract covers the generated entry points, the loader's fixed-size C5
allocation, and the front-end payload moved to C9. It does not claim native
framebuffer bindings or visual stability; those require a running J9 check.
"""

import argparse
import json
from pathlib import Path
import re

if __package__:
    from .preview.shader_source import inline_shader
else:
    from preview.shader_source import inline_shader


PROFILE_SIDES = {"LOW": 32, "MID": 48, "HIGH": 64, "ULTRA": 96}
IMAGE_DECLARATION = re.compile(
    r"layout\s*\(\s*r32ui\s*,\s*binding\s*=\s*5\s*\)"
    r"\s*uniform\s+uimage2D\s+colorimg5\s*;"
)


def require(condition, message):
    """Report a concrete broken resource contract without suppressing it."""
    if not condition:
        raise ValueError(message)


def render_targets(source):
    """Read both OptiFine output-directive syntaxes, including disabled slots."""
    pattern = r"\b(RENDERTARGETS|DRAWBUFFERS)\s*:\s*([0-9N, \t]+)"
    for match in re.finditer(pattern, source):
        values = match[2].split(",") if match[1] == "RENDERTARGETS" else match[2].strip()
        yield [int(value) for value in values if value.strip() != "N"]


def check_pack(root):
    """Validate allocation, image access, and the complete front-end relocation."""
    manifest = json.loads((root / "conventional-build.json").read_text(encoding="utf-8"))
    settings = (root / "settings.glsl").read_text(encoding="utf-8")
    properties = (root / "shaders.properties").read_text(encoding="utf-8")
    side = PROFILE_SIDES[manifest["preset"]]
    shape = [side, side // 2, side]
    require(manifest.get("voxel_storage") == "detached-colortex5-image", "Wrong voxel storage")
    require(manifest.get("voxel_shape") == shape, "Manifest voxel shape differs from the profile")
    require(manifest.get("voxel_format") == "R32UI", "Manifest voxel format must be R32UI")
    require("const int colortex5Format = R32UI;" in settings, "C5 must use R32UI")
    require("const bool colortex5Clear = false;" in settings, "C5 must avoid raster clearing")
    require("const int colortex9Format = RGBA32F;" in settings, "C9 lost the front-end format")
    require("const bool colortex9Clear = true;" in settings, "C9 lost the front-end clear flag")
    require("const vec4 colortex9ClearColor = vec4(0.0, 0.0, 0.0, 0.0);" in settings,
            "C9 lost the front-end clear colour")
    require("blend.gbuffers_water.colortex9=ONE ONE_MINUS_SRC_ALPHA ONE ONE_MINUS_SRC_ALPHA" in properties,
            "Water data blend did not move to C9")
    require(not re.search(r"^(?:blend|flip)\.[^\n=]*\bcolortex5\b", properties, re.M),
            "A raster blend or flip directive still targets C5")
    require(not re.search(r"^size\.buffer\.colortex9\s*=", properties, re.M),
            "Front-end C9 must retain the scene dimensions")

    # J9 detaches a fixed-size C5 from its scene framebuffer. Check every
    # selectable profile, since a screen-sized fallback would restore aliasing.
    capacities = {}
    branches = re.finditer(
        r"#(?:if|elif) COLOURED_VOLUME_SIZE == (\d+)\n(.*?)(?=#elif|#endif)",
        properties,
        re.S,
    )
    for branch in branches:
        budget = int(branch[1])
        allocation = re.search(r"^size\.buffer\.colortex5=(\d+) (\d+)$", branch[2], re.M)
        if allocation is None and "size.buffer.colortex12=" in branch[2]:
            continue
        require(allocation is not None, f"C5 is not fixed-size for side {budget}")
        width, height = map(int, allocation.groups())
        cells = budget * (budget // 2) * budget
        words_per_cell = 25 if "reflection_faces" in manifest else (2 if "reflection_geometry" in manifest else 1)
        require(width * height == cells * words_per_cell, f"C5 capacity differs from the {budget}-cell volume and face suffix")
        require(width <= 16384 and height <= 16384, "C5 exceeds the target texture dimension limit")
        capacities[budget] = [width, height]
    require(set(capacities) == set(PROFILE_SIDES.values()), "C5 allocation misses a profile")
    require("#endif\n#else\nsize.buffer.colortex5=1 1\n" in properties,
            "Disabling both GI and coloured lighting must retain detached 1x1 C5")

    entries = []
    for dimension in ("", "world-1", "world1"):
        folder = root / dimension
        for name in ("shadow.vsh", "shadow.csh", "gbuffers_water.fsh"):
            require((folder / name).is_file(), f"Missing native entry point: {dimension}/{name}")
        for path in folder.glob("*.?sh"):
            source = inline_shader(path, root)
            relative = path.relative_to(root)
            require(source.startswith("#version 450 core\n"), f"{relative}: native stage is not GLSL 450")
            require(all(5 not in targets for targets in render_targets(source)),
                    f"{relative}: raster output still targets voxel C5")
            require(not re.search(r"\buniform\s+[ui]?sampler\w*\s+colortex5\b", source),
                    f"{relative}: voxel C5 is still accessed through a sampler")
            require(not re.search(r"\bshadowcolor(?:img)?1\b", source),
                    f"{relative}: obsolete shadow voxel storage remains")
            if "colorimg5" in source:
                require(len(IMAGE_DECLARATION.findall(source)) == 1,
                        f"{relative}: expected one R32UI image declaration at binding 5")
            if path.name == "shadow.vsh":
                require("imageAtomicMax(colorimg5," in source, f"{relative}: native capture misses C5")
            if path.name == "shadow.csh":
                require("imageStore(colorimg5," in source, f"{relative}: compute clear misses C5")
            if path.name == "gbuffers_water.fsh":
                require([0, 1, 2, 9, 7] in list(render_targets(source)),
                        f"{relative}: water output routing did not move to C9")
                require("imageLoad(colorimg5," in source, f"{relative}: material consumer misses C5")
            entries.append(str(relative))
    return {
        "path": str(root.resolve()),
        "preset": manifest["preset"],
        "coloured": manifest["colored_lighting"],
        "native_stages": len(entries),
        "voxel_shape": shape,
        "voxel_image_size": capacities[side]
            if manifest["colored_lighting"] or manifest.get("gi_quality", 0) > 0 else [1, 1],
        "raster_target_5": False,
        "passed": True,
    }


def main():
    """Check one or more already assembled packs without launching Minecraft."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shader-dir", type=Path, action="append", required=True)
    args = parser.parse_args()
    reports = []
    for root in args.shader_dir:
        try:
            reports.append(check_pack(root))
        except (KeyError, OSError, ValueError) as failure:
            reports.append({"path": str(root.resolve()), "passed": False, "error": str(failure)})
    print(json.dumps(reports, indent=2))
    return 0 if all(report["passed"] for report in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
