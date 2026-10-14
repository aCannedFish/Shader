"""Real-frame checks for underwater visibility, refraction and foreground continuity."""

import json
import re
import shutil

from PIL import Image, ImageChops, ImageStat

from .replay import render

SCENES = (
    "underwater_shallow", "underwater_deep", "underwater_air", "underwater_air_deep",
    "underwater_interface", "underwater_magma_dark", "underwater_magma_lit",
)


def verify_underwater(root, runtime, converter, baseline=None):
    """Compare parameter variants with identical captured geometry, lighting and time."""
    work = root / ".preview/underwater-verification"
    work.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((root / ".preview/manifest.json").read_text())
    available = {scene["name"] for scene in manifest["scenes"]}
    selected = tuple(name for name in SCENES if name in available)
    required = set(SCENES[:4])
    if not required.issubset(available):
        raise RuntimeError("Capture the shallow, deep and upward underwater scenes first")
    if baseline is None:
        baseline = work / "baseline"
        render(root, runtime, converter, names=selected, output=baseline)

    def image(directory, name):
        return Image.open(directory / (name + ".png")).convert("RGB")

    def mean_difference(first, second, name, box=None):
        a = image(first, name)
        b = image(second, name)
        if box is not None:
            a = a.crop(box)
            b = b.crop(box)
        return sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3.0

    def variant(name, options=None, edits=(), scenes=selected):
        shaders = work / (name + "-shaders")
        shutil.copytree(root / "shaders", shaders, dirs_exist_ok=True)
        path = shaders / "settings.glsl"
        text = path.read_text()
        for option, value in (options or {}).items():
            text, count = re.subn(
                r"(^#define " + re.escape(option) + r" )[^\s]+",
                lambda match: match[1] + str(value), text, flags=re.MULTILINE,
            )
            if count != 1:
                raise RuntimeError(f"Unknown underwater setting: {option}")
        path.write_text(text)
        for filename, before, after in edits:
            path = shaders / filename
            text = path.read_text()
            if before not in text:
                raise RuntimeError(f"Underwater verification edit no longer applies: {filename}")
            path.write_text(text.replace(before, after, 1))
        destination = work / name
        render(root, runtime, converter, names=scenes, shader_root=shaders, output=destination)
        return destination

    box = (240, 220, 1680, 950)
    brightness = {
        name: ImageStat.Stat(image(baseline, name).convert("L").crop(box)).mean[0]
        for name in SCENES[:4]
    }
    if brightness["underwater_deep"] >= brightness["underwater_shallow"]:
        raise RuntimeError("Deep water does not attenuate the submerged scene")
    if brightness["underwater_air_deep"] >= brightness["underwater_air"]:
        raise RuntimeError("Deep immersion does not attenuate the surface view")
    if brightness["underwater_deep"] < 8.0:
        raise RuntimeError("The deep scene has insufficient nearby visibility")

    dense = variant("dense", {"UNDERWATER_DENSITY": 2.0}, scenes=SCENES[:4])
    density_changes = {
        name: mean_difference(baseline, dense, name, box) for name in SCENES[:4]
    }
    if max(density_changes.values()) <= 0.5:
        raise RuntimeError("Underwater density has no visible effect")

    air_scenes = tuple(name for name in selected if name.startswith("underwater_air")
                       or name == "underwater_interface")
    straight = variant("straight", {"WATER_REFRACTION_STRENGTH": 0.0}, scenes=air_scenes)
    refraction_changes = {
        name: mean_difference(baseline, straight, name, box) for name in air_scenes
    }
    if max(refraction_changes.values()) <= 0.005:
        raise RuntimeError("Underwater wave distortion has no visible effect")

    no_floor = variant("no-floor", {"UNDERWATER_MIN_VISIBILITY": 0.0},
                       scenes=("underwater_deep", "underwater_air_deep"))
    no_floor_brightness = ImageStat.Stat(
        image(no_floor, "underwater_deep").convert("L").crop(box)
    ).mean[0]
    if brightness["underwater_deep"] <= no_floor_brightness + 1.0:
        raise RuntimeError("The minimum visibility setting does not preserve nearby detail")

    foreground_difference = None
    interface_difference = None
    if "underwater_interface" in available:
        reference_options = {
            "WATER_CAUSTICS_STRENGTH": 0.0,
            "UNDERWATER_SHAFT_STRENGTH": 0.0,
            "WATER_REFRACTION_STRENGTH": 0.0,
        }
        foreground_baseline = variant("foreground-baseline", reference_options,
                                      scenes=("underwater_interface",))
        reference = variant("opaque-reference", reference_options, edits=[(
            "composite2.fsh", "color = applyUnderwaterOptics(screenCoord, depth);",
            "color = applyUnderwaterVolume(texture2D(colortex6, screenCoord).rgb, "
            "length(screenToView(screenCoord, texture2D(depthtex1, screenCoord).r)), "
            "estimateUnderwaterDepth());",
        )], scenes=("underwater_interface",))
        # This crop lies on the submerged face of the column, below the waterline.
        # It must match one sharp opaque sample with volume attenuation alone.
        foreground_difference = mean_difference(
            foreground_baseline, reference, "underwater_interface", (840, 650, 925, 1000),
        )
        if foreground_difference > 0.1:
            raise RuntimeError(f"Surface optics contaminate foreground geometry: {foreground_difference}")

        # The air-facing part must have a visible surface layer while the same
        # submerged column remains unchanged when that layer is disabled.
        no_interface = variant("no-interface", reference_options, edits=[(
            "lib/underwater.glsl",
            "vec3 interfaceColor = mix(air, reflected, reflectionWeight);",
            "vec3 interfaceColor = air;",
        )], scenes=("underwater_interface",))
        interface_difference = mean_difference(
            foreground_baseline, no_interface, "underwater_interface", (600, 260, 1300, 600),
        )
        if interface_difference <= 3.0:
            raise RuntimeError(f"Underwater surface layer is not visible: {interface_difference}")
        if mean_difference(foreground_baseline, no_interface, "underwater_interface",
                           (840, 650, 925, 1000)) > 0.1:
            raise RuntimeError("Underwater surface layer changes submerged foreground")

    magma_change = None
    if {"underwater_magma_dark", "underwater_magma_lit"}.issubset(available):
        difference = ImageChops.difference(image(baseline, "underwater_magma_dark"),
                                           image(baseline, "underwater_magma_lit"))
        magma_change = sum(ImageStat.Stat(difference).mean) / 3.0
        if magma_change <= 0.2:
            raise RuntimeError("The submerged magma source is not visible")

    sky_line_pixels = None
    if "sky_direction_270" in available:
        sky_output = work / "sky-gap"
        render(root, runtime, converter, names=("sky_direction_270",), output=sky_output)
        pixels = image(sky_output, "sky_direction_270").load()
        sky_line_pixels = sum(
            sum(pixels[959, y]) - max(sum(pixels[957, y]), sum(pixels[961, y])) > 18
            for y in range(447, 650)
        )
        if sky_line_pixels > 5:
            raise RuntimeError(f"The sky gap remains visible: {sky_line_pixels} pixels")

    distant_water_fog_change = None
    if "water_far" in available:
        edge_baseline = work / "water-edge"
        render(root, runtime, converter, names=("water_far",), output=edge_baseline)
        no_edge_fog = variant("no-edge-fog", edits=[(
            "lib/water_reflection.glsl", "result = applyFog(result, length(position));",
            "result = result;",
        )], scenes=("water_far",))
        distant_water_fog_change = mean_difference(edge_baseline, no_edge_fog, "water_far")
        if distant_water_fog_change <= 0.005:
            raise RuntimeError("Distant water does not receive edge fog")

    result = {
        "brightness": brightness,
        "density_mean_changes": density_changes,
        "refraction_mean_changes": refraction_changes,
        "deep_brightness_without_visibility_floor": no_floor_brightness,
        "foreground_reference_mean_error": foreground_difference,
        "interface_mean_change": interface_difference,
        "magma_mean_change": magma_change,
        "sky_line_pixels": sky_line_pixels,
        "distant_water_fog_mean_change": distant_water_fog_change,
    }
    (work / "verification.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), flush=True)
    return result
