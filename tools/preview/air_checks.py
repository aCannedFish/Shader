"""Real-GPU ablations for restrained, shadowed near-ground sunlight scattering."""

import json
import re
import shutil

from PIL import Image, ImageChops, ImageStat

from .replay import render


SCENES = (
    "sunshafts_sunrise", "sunshafts_sunrise_motion", "sunshafts_sunset",
    "sunshafts_oblique", "sunshafts_oblique_motion",
    "sunshafts_noon", "sunshafts_night", "sunshafts_room",
    "water_depth_steps", "underwater_interface",
)


def verify_air(root, runtime, converter, baseline=None):
    """Check visibility, shadow dependence, night shutdown and water isolation."""
    work = root / ".preview/air-verification"
    work.mkdir(parents=True, exist_ok=True)
    if baseline is None:
        baseline = work / "baseline"
        render(root, runtime, converter, names=SCENES, output=baseline)

    def variant(name, disabled=False, unshadowed=False, scenes=SCENES):
        """Change one optical input while retaining captured geometry and time."""
        shaders = work / (name + "-shaders")
        shutil.copytree(root / "shaders", shaders, dirs_exist_ok=True)
        if disabled:
            path = shaders / "settings.glsl"
            text, count = re.subn(r"(^#define AIR_SCATTER_STRENGTH )[^\s]+",
                                  lambda match: match[1] + "0.0", path.read_text(),
                                  flags=re.MULTILINE)
            if count != 1:
                raise RuntimeError("Missing air scattering control")
            path.write_text(text)
        if unshadowed:
            path = shaders / "lib/air_scattering.glsl"
            text = path.read_text()
            before = "float visibility = airSunVisibility(relative);"
            if before not in text:
                raise RuntimeError("Air shadow ablation no longer matches")
            path.write_text(text.replace(before, "float visibility = 1.0;", 1))
        output = work / name
        render(root, runtime, converter, names=scenes, shader_root=shaders, output=output)
        return output

    def image(directory, name):
        return Image.open(directory / (name + ".png")).convert("RGB")

    def difference(first, second, name, box=None):
        a, b = image(first, name), image(second, name)
        if box:
            a, b = a.crop(box), b.crop(box)
        return sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3.0

    disabled = variant("disabled", disabled=True)
    changes = {name: difference(baseline, disabled, name) for name in SCENES}
    for name in ("sunshafts_sunrise", "sunshafts_sunset", "sunshafts_oblique"):
        if changes[name] <= 0.15:
            raise RuntimeError(f"Low-angle air scattering is not visible: {name}")
    if changes["sunshafts_noon"] >= max(changes["sunshafts_sunrise"], changes["sunshafts_sunset"]):
        raise RuntimeError("Noon scattering overwhelms the low-angle fixtures")
    for name in ("sunshafts_night", "underwater_interface"):
        if changes[name] > 0.01:
            raise RuntimeError(f"Air scattering leaks into {name}: {changes[name]}")

    room_on = ImageStat.Stat(image(baseline, "sunshafts_room").convert("L")).mean[0]
    room_off = ImageStat.Stat(image(disabled, "sunshafts_room").convert("L")).mean[0]
    if room_on - room_off > 0.1:
        raise RuntimeError("Sunlight scattering brightens the sealed interior")

    # A darker or tinted frame is insufficient: normally displayed forest
    # pixels must gain visible light, without creating a broad clipped glow.
    beam_box = (160, 200, 1760, 1000)
    forest_on = image(baseline, "sunshafts_oblique").convert("L").crop(beam_box)
    forest_off = image(disabled, "sunshafts_oblique").convert("L").crop(beam_box)
    added_light = ImageChops.subtract(forest_on, forest_off)
    visible_fraction = sum(value >= 8 for value in added_light.get_flattened_data())
    visible_fraction /= added_light.width * added_light.height
    added_mean = ImageStat.Stat(added_light).mean[0]
    if added_mean < 1.0 or visible_fraction < 0.03:
        raise RuntimeError(f"Forest rays are not visible: mean={added_mean}, coverage={visible_fraction}")
    clipped_on = sum(value >= 250 for value in forest_on.get_flattened_data())
    clipped_off = sum(value >= 250 for value in forest_off.get_flattened_data())
    if (clipped_on - clipped_off) / (forest_on.width * forest_on.height) > 0.003:
        raise RuntimeError("The volume layer creates a broad clipped highlight")

    low_sun = ("sunshafts_sunrise", "sunshafts_sunset", "sunshafts_oblique")
    unshadowed = variant("unshadowed", unshadowed=True, scenes=low_sun)
    shadow_changes = {
        name: difference(baseline, unshadowed, name, (200, 480, 1720, 1050))
        for name in low_sun
    }
    if min(shadow_changes.values()) <= 0.01 or max(shadow_changes.values()) <= 0.05:
        raise RuntimeError("Occluders do not modulate the air scattering")
    if shadow_changes["sunshafts_oblique"] < 0.5:
        raise RuntimeError("The forest volume lacks visible light/shadow separation")

    result = {
        "mean_changes": changes,
        "room_luminance_change": room_on - room_off,
        "shadow_mean_changes": shadow_changes,
        "forest_added_light_mean": added_mean,
        "forest_visible_ray_fraction": visible_fraction,
        "display_channel_range": [0, 255],
    }
    (work / "verification.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), flush=True)
    return result
