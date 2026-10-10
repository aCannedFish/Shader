"""Real-GPU comparisons for water controls and smooth local light under shadows.

Only code/options compatible with the captured host configuration are changed.
Masks isolate water geometry and a known neutral floor; texture details are not
blurred or mistaken for light-field discontinuities.
"""

import json
import re
import shutil

from PIL import Image, ImageChops, ImageFilter, ImageStat

from .replay import render

SCENES = ("water", "water_reflection", "water_cave_dark", "water_cave_lit",
          "water_cave_night", "local_shadow_dark", "local_shadow_lit", "local_light_night")


def verify_materials(root, runtime, converter):
    """Reject missing water, ineffective controls, sunlight leaks and stepped light."""
    work = root / ".preview" / "material-verification"
    work.mkdir(parents=True, exist_ok=True)
    settings = (root / "shaders" / "settings.glsl").read_text()
    defaults = dict(re.findall(r"^#define (\w+) ([^\s]+)", settings, re.MULTILINE))
    baseline = work / "baseline"
    render(root, runtime, converter, names=SCENES, output=baseline)

    def variant(name, options=None, edits=(), scenes=SCENES):
        """Apply private, reversible option/source changes and replay selected cases."""
        shaders = work / (name + "-shaders")
        shutil.copytree(root / "shaders", shaders, dirs_exist_ok=True)
        source = shaders / "settings.glsl"
        text = source.read_text()
        for option, value in (options or {}).items():
            text = re.sub(r"(^#define " + re.escape(option) + r" )[^\s]+",
                          lambda match: match[1] + str(value), text, flags=re.MULTILINE)
        source.write_text(text)
        for filename, before, after in edits:
            source = shaders / filename
            text = source.read_text()
            if before not in text:
                raise RuntimeError(f"Material verification edit no longer applies: {filename}")
            source.write_text(text.replace(before, after, 1))
        destination = work / name
        render(root, runtime, converter, names=scenes, shader_root=shaders, output=destination)
        return destination

    def image(directory, scene):
        return Image.open(directory / (scene + ".png")).convert("RGB")

    mask_code = """vec3 probePosition = viewToAbsoluteWorld(screenToView(screenCoord, depth));
    bool floorProbe = depth < 0.999999 && abs(probePosition.y - 81.0) < 0.025
        && probePosition.x > -42.9 && probePosition.x < -21.1
        && probePosition.z > -12.9 && probePosition.z < 8.9;
    bool waterProbe = texture2D(colortex5, screenCoord).a > 0.001;
    color = vec3(floorProbe || waterProbe ? 1.0 : 0.0);
    gl_FragData[0] = vec4(color, 1.0);"""
    mask_directory = variant("mask", edits=[
        ("composite1.fsh", "gl_FragData[0] = vec4(color, 1.0);", mask_code),
    ])
    masks = {scene: image(mask_directory, scene).convert("L").point(lambda v: 255 if v > 180 else 0)
             for scene in SCENES}
    if any(not mask.getbbox() for mask in masks.values()):
        raise RuntimeError("A water/floor probe is absent; check alpha testing and geometry")

    def difference(first, second, scene):
        delta = ImageChops.difference(image(first, scene), image(second, scene))
        return sum(ImageStat.Stat(delta, masks[scene]).mean) / 3.0

    water_scene = ["water"]
    cases = {
        "texture-on": {"ENABLE_WATER_TEXTURE": 1},
        "no-refraction": {"WATER_REFRACTION_STRENGTH": 0.0},
        "strong-reflection": {"WATER_REFLECTION_STRENGTH": 1.0},
        "turbid": {"WATER_TURBIDITY": 0.10},
        "no-medium": {"WATER_SURFACE_OPACITY": 0.0, "WATER_TURBIDITY": 0.0,
                      "WATER_ABSORPTION": 0.0, "WATER_REFLECTION_STRENGTH": 0.0,
                      "WATER_REFRACTION_STRENGTH": 0.0},
    }
    control_changes = {}
    for name, options in cases.items():
        output = variant(name, options, scenes=water_scene)
        control_changes[name] = difference(baseline, output, "water")
        if control_changes[name] <= 0.1:
            raise RuntimeError(f"Water control has no visible effect: {name}")
    if control_changes["no-medium"] <= 2.0:
        raise RuntimeError("Default water is visually indistinguishable from an empty pool")

    caves = ["water_cave_dark", "water_cave_lit", "water_cave_night"]
    no_sun = variant("no-sun", {"SUNLIGHT_STRENGTH": 0.0}, scenes=caves)
    solar_errors = {scene: difference(baseline, no_sun, scene) for scene in caves}
    if max(solar_errors.values()) > 0.15:
        raise RuntimeError(f"Solar illumination leaks into the closed water volume: {solar_errors}")

    lights = ["local_shadow_lit", "local_light_night"]
    no_local = variant("no-local-light", {"BLOCK_LIGHT_STRENGTH": 0.0}, scenes=lights)
    local_fill = {}
    for scene in lights:
        lit = ImageStat.Stat(image(baseline, scene).convert("L"), masks[scene]).mean[0]
        unlit = ImageStat.Stat(image(no_local, scene).convert("L"), masks[scene]).mean[0]
        local_fill[scene] = lit - unlit
        if local_fill[scene] <= 10.0:
            raise RuntimeError(f"Local light does not fill the solar shadow/night floor: {scene}")

    profile_edit = [("gbuffers_terrain.fsh",
        "vec3 color = computeSurfaceLighting(albedo.rgb, normalView, lmCoord, shadow, occlusion, vViewPos);",
        "vec3 color = blockLightRadiance(lmCoord);")]
    profile_scene = ["local_light_night"]
    smooth = variant("light-smooth", {"SMOOTH_BLOCK_LIGHT": 1}, profile_edit, profile_scene)
    stepped = variant("light-stepped", {"SMOOTH_BLOCK_LIGHT": 0}, profile_edit, profile_scene)
    mask = masks["local_light_night"].filter(ImageFilter.MinFilter(9))
    edge_energy = {}
    for name, directory in (("smooth", smooth), ("stepped", stepped)):
        edges = image(directory, "local_light_night").convert("L").filter(ImageFilter.FIND_EDGES)
        edge_energy[name] = ImageStat.Stat(edges, mask).mean[0]
    if edge_energy["smooth"] >= edge_energy["stepped"]:
        raise RuntimeError(f"Light interpolation does not reduce hard transitions: {edge_energy}")

    result = {"defaults": defaults, "water_control_mean_changes": control_changes,
              "cave_solar_mean_errors": solar_errors, "local_light_luminance_gain": local_fill,
              "light_field_edge_energy": edge_energy,
              "water_visible_pixels": sum(v > 0 for v in masks["water"].get_flattened_data())}
    (work / "verification.json").write_text(json.dumps(result, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key != "defaults"}, indent=2), flush=True)
    return result
