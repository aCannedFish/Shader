"""Check water lighting and reflections using captured, real OpenGL frames.

Private shader variants isolate solar illumination, water coverage, reflected
radiance and wave motion. These checks exercise the renderer and scene inputs;
no synthetic image is substituted for a GPU result.
"""

import json
import re
import shutil

from PIL import Image, ImageChops, ImageFilter, ImageStat

from .replay import render

WATER_SCENES = (
    "water_reflection", "water_reflection_motion", "water_cave_dark",
    "water_cave_lit", "water_cave_night", "water_glass",
)


def verify_water(root, runtime, converter):
    """Export controlled variants and reject missing or unoccluded reflections."""
    work = root / ".preview" / "water-verification"
    work.mkdir(parents=True, exist_ok=True)
    baseline = render(root, runtime, converter, names=WATER_SCENES, output=work / "baseline")
    current_changed_pixels = sum(scene["changed_pixels"] for scene in baseline["scenes"])
    if current_changed_pixels:
        # Ordinary source edits should not require Minecraft. Validate the
        # captured source separately, then compare variants to the current code.
        captured_shaders = root / ".preview" / "game" / "shaderpacks" / "SimpleShader" / "shaders"
        reference = render(root, runtime, converter, names=WATER_SCENES,
                           shader_root=captured_shaders, output=work / "captured-reference")
        if any(scene["changed_pixels"] for scene in reference["scenes"]):
            raise RuntimeError("Captured water programs do not reproduce their reference images")

    def option(name, value):
        """Use the current default instead of assuming an older material preset."""
        settings = (root / "shaders" / "settings.glsl").read_text()
        match = re.search(r"^#define " + re.escape(name) + r" ([^\s]+)", settings, re.MULTILINE)
        if match is None:
            raise RuntimeError(f"Missing shader option: {name}")
        return ("settings.glsl", match.group(0), f"#define {name} {value}")

    def variant(name, changes, scenes=WATER_SCENES):
        """Copy source and change only shader code/options compatible with replay."""
        shaders = work / (name + "-shaders")
        shutil.copytree(root / "shaders", shaders, dirs_exist_ok=True)
        for filename, before, after in changes:
            source = shaders / filename
            text = source.read_text()
            if before not in text:
                raise RuntimeError(f"Water check edit no longer applies: {filename}: {before}")
            source.write_text(text.replace(before, after, 1))
        destination = work / name
        render(root, runtime, converter, names=scenes, shader_root=shaders, output=destination)
        return destination

    def image(directory, scene):
        return Image.open(directory / (scene + ".png")).convert("RGB")

    mask_directory = variant("mask", [
        ("composite1.fsh", "gl_FragData[0] = vec4(color, 1.0);",
         "color = vec3(step(0.001, texture2D(colortex5, screenCoord).a));\n    gl_FragData[0] = vec4(color, 1.0);"),
    ])
    masks = {scene: image(mask_directory, scene).convert("L").point(lambda value: 255 if value > 12 else 0)
             for scene in WATER_SCENES}
    # Limit measurements to the visible pool and leave boundary geometry out.
    for mask in masks.values():
        mask.paste(0, (0, 0, mask.width, mask.height // 2))
    if any(not mask.getbbox() for mask in masks.values()):
        raise RuntimeError("A water fixture has no visible top surface")

    def error(first, second, scene):
        difference = ImageChops.difference(image(first, scene), image(second, scene))
        return sum(ImageStat.Stat(difference, masks[scene]).mean) / 3.0

    no_sun = variant("no-sun", [
        ("settings.glsl", "#define SUNLIGHT_STRENGTH 1.0", "#define SUNLIGHT_STRENGTH 0.0"),
    ])
    solar_errors = {scene: error(work / "baseline", no_sun, scene)
                    for scene in ("water_cave_dark", "water_cave_lit", "water_cave_night")}
    if max(solar_errors.values()) > 0.15:
        raise RuntimeError(f"Sun/moon illumination leaks into the sealed water fixture: {solar_errors}")
    no_reflection = variant("no-reflection", [
        option("WATER_REFLECTION_STRENGTH", "0.0"),
    ])
    reflection_errors = {scene: error(work / "baseline", no_reflection, scene)
                         for scene in ("water_reflection", "water_cave_lit")}
    if min(reflection_errors.values()) <= 0.5:
        raise RuntimeError(f"Reflections are missing in an outdoor/lit cave fixture: {reflection_errors}")

    # Expose the reflected radiance to compare motion/blur independently of diffuse water colour.
    reflection_only = ("lib/water_reflection.glsl", "return result;", "return reflected;")
    freeze_clouds = ("settings.glsl", "#define CLOUD_SPEED 0.6", "#define CLOUD_SPEED 0.0")
    moving = variant("moving-reflection", [reflection_only, freeze_clouds], WATER_SCENES[:2])
    still = variant("still-reflection", [reflection_only, freeze_clouds,
        ("settings.glsl", "#define ENABLE_WATER_WAVES 1", "#define ENABLE_WATER_WAVES 0"),
    ], WATER_SCENES[:2])
    motion_mask = ImageChops.multiply(masks[WATER_SCENES[0]], masks[WATER_SCENES[1]])

    def temporal_error(directory):
        difference = ImageChops.difference(image(directory, WATER_SCENES[0]), image(directory, WATER_SCENES[1]))
        return sum(ImageStat.Stat(difference, motion_mask).mean) / 3.0

    moving_error = temporal_error(moving)
    still_error = temporal_error(still)
    if moving_error <= still_error + 0.5:
        raise RuntimeError(f"Wave motion does not change the reflection: moving={moving_error}, still={still_error}")
    sharp = variant("sharp-reflection", [reflection_only, freeze_clouds,
        option("WATER_ROUGHNESS", "0.04"),
    ], ["water_reflection"])
    rough = variant("rough-reflection", [reflection_only, freeze_clouds,
        option("WATER_ROUGHNESS", "0.35"),
    ], ["water_reflection"])
    mask = masks["water_reflection"].filter(ImageFilter.MinFilter(7))
    edge_energy = {}
    for name, directory in (("sharp", sharp), ("rough", rough)):
        edges = image(directory, "water_reflection").convert("L").filter(ImageFilter.FIND_EDGES)
        edge_energy[name] = ImageStat.Stat(edges, mask).mean[0]
    if edge_energy["rough"] >= edge_energy["sharp"]:
        raise RuntimeError(f"Roughness does not soften reflection detail: {edge_energy}")

    luminance = {scene: ImageStat.Stat(image(work / "baseline", scene).convert("L"), masks[scene]).mean[0]
                 for scene in ("water_reflection", "water_cave_dark", "water_cave_lit")}
    if not luminance["water_cave_dark"] < luminance["water_cave_lit"] < luminance["water_reflection"]:
        raise RuntimeError(f"Local illumination ordering is incorrect: {luminance}")
    result = {
        "baseline_equal": True, "current_changed_pixels": current_changed_pixels,
        "cave_solar_mean_error": solar_errors,
        "reflection_mean_change": reflection_errors, "reflection_motion_mean_change": moving_error,
        "still_reflection_mean_change": still_error, "reflection_edge_energy": edge_energy,
        "water_luminance": luminance,
    }
    (work / "verification.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return result
