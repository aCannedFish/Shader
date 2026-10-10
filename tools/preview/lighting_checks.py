"""GPU regressions for block entities, night clouds and local shadow fill.

World-space masks isolate known neutral surfaces. Shadow contrast is measured
against the same frame with only directional visibility removed, so texture,
light distance and exposure are held constant.
"""

import json
import re
import shutil

from PIL import Image, ImageChops, ImageFilter, ImageStat

from .replay import render

SCENES = (
    "lighting_bed_day", "lighting_bed_night", "lighting_bed_lit",
    "lighting_shadow_day_dark", "lighting_shadow_day_lit",
    "lighting_shadow_night_dark", "lighting_shadow_night_lit",
    "clouds", "clouds_night",
)


def verify_lighting(root, runtime, converter):
    """Check night material response and per-light shadow independence on the GPU."""
    work = root / ".preview" / "lighting-verification"
    work.mkdir(parents=True, exist_ok=True)
    baseline = work / "baseline"
    render(root, runtime, converter, names=SCENES, output=baseline)

    def variant(name, options=None, edits=(), scenes=SCENES):
        """Replay private source changes without modifying the working shader pack."""
        shaders = work / (name + "-shaders")
        shutil.copytree(root / "shaders", shaders, dirs_exist_ok=True)
        settings = shaders / "settings.glsl"
        text = settings.read_text()
        for option, value in (options or {}).items():
            text = re.sub(r"(^#define " + re.escape(option) + r" )[^\s]+",
                          lambda match: match[1] + str(value), text, flags=re.MULTILINE)
        settings.write_text(text)
        for filename, before, after in edits:
            source = shaders / filename
            text = source.read_text()
            if before not in text:
                raise RuntimeError(f"Lighting probe no longer applies: {filename}")
            source.write_text(text.replace(before, after, 1))
        destination = work / name
        render(root, runtime, converter, names=scenes, shader_root=shaders, output=destination)
        return destination

    def image(directory, scene):
        return Image.open(directory / (scene + ".png")).convert("RGB")

    def mean(directory, scene, mask):
        return ImageStat.Stat(image(directory, scene).convert("L"), mask).mean[0]

    mask_code = """vec3 probe = viewToAbsoluteWorld(screenToView(screenCoord, depth));
    bool bedProbe = depth < 0.999999 && probe.x > -74.98 && probe.x < -74.02
        && probe.z > 49.02 && probe.z < 50.98 && probe.y > 81.5 && probe.y < 81.6;
    bool woolProbe = depth < 0.999999 && probe.x > -72.98 && probe.x < -72.02
        && probe.z > 49.02 && probe.z < 50.98 && abs(probe.y - 82.0) < 0.025;
    bool floorProbe = depth < 0.999999 && abs(probe.y - 81.0) < 0.025
        && probe.x > -79.8 && probe.x < -60.2 && probe.z > 38.2 && probe.z < 64.8
        && length(probe.xz - vec2(-72.5, 52.5)) < 6.0;
    bool cloudProbe = cameraPosition.y > 150.0 && cloud.a > 0.2;
    color = vec3(bedProbe || cloudProbe ? 1.0 : 0.0,
                 woolProbe ? 1.0 : 0.0, floorProbe ? 1.0 : 0.0);
    gl_FragData[0] = vec4(color, 1.0);"""
    mask_directory = variant("masks", {"ENABLE_BLOOM": 0}, edits=[
        ("composite1.fsh", "gl_FragData[0] = vec4(color, 1.0);", mask_code),
    ])
    masks = {}
    for scene in SCENES:
        channels = image(mask_directory, scene).split()
        masks[scene] = tuple(channel.point(lambda value: 255 if value > 150 else 0)
                             for channel in channels)

    bed_brightness = {}
    wool_brightness = {}
    for scene in SCENES[:3]:
        if not masks[scene][0].getbbox() or not masks[scene][1].getbbox():
            raise RuntimeError(f"Missing bed/wool surfaces: {scene}")
        bed_brightness[scene] = mean(baseline, scene, masks[scene][0])
        wool_brightness[scene] = mean(baseline, scene, masks[scene][1])
    if bed_brightness[SCENES[1]] >= bed_brightness[SCENES[0]] * 0.3:
        raise RuntimeError("Non-emissive bed stays bright at night")
    night_ratio = bed_brightness[SCENES[1]] / max(wool_brightness[SCENES[1]], 1.0)
    if not 0.45 < night_ratio < 1.8:
        raise RuntimeError(f"Bed lighting disagrees with adjacent neutral terrain: {night_ratio}")
    if bed_brightness[SCENES[2]] < bed_brightness[SCENES[1]] + 15.0:
        raise RuntimeError("Block-entity bed does not receive local light")

    shadow_scenes = SCENES[3:7]
    no_shadow = variant("no-directional-shadow", edits=[
        ("gbuffers_terrain.fsh",
         "float shadow = getShadowFactor(vShadowClipPos, normalView, viewDistance);",
         "float shadow = 1.0;"),
    ], scenes=shadow_scenes)
    shadow_contrast = {}
    local_gain = {}
    for phase in ("day", "night"):
        dark = f"lighting_shadow_{phase}_dark"
        lit = f"lighting_shadow_{phase}_lit"
        deficit = ImageChops.subtract(image(no_shadow, dark).convert("L"),
                                     image(baseline, dark).convert("L"))
        threshold = 10 if phase == "day" else 2
        shadow_pixels = deficit.point(lambda value: 255 if value > threshold else 0)
        probe = ImageChops.multiply(masks[lit][2], shadow_pixels).filter(ImageFilter.MinFilter(3))
        if not probe.getbbox():
            raise RuntimeError(f"No shadowed floor samples near the light: {phase}")
        for scene in (dark, lit):
            reference = mean(no_shadow, scene, probe)
            shadow_contrast[scene] = (reference - mean(baseline, scene, probe)) / max(reference, 1.0)
        local_gain[phase] = mean(baseline, lit, probe) - mean(baseline, dark, probe)
        if shadow_contrast[lit] >= shadow_contrast[dark] * 0.5 or local_gain[phase] <= 15.0:
            raise RuntimeError(f"Local light leaves excessive {phase} shadow contrast: {shadow_contrast}")
    if shadow_contrast["lighting_shadow_night_lit"] >= 0.03:
        raise RuntimeError("Moon shadow remains dominant within local illumination")

    cloud_scenes = SCENES[-2:]
    cloud_only = variant("cloud-radiance", edits=[
        ("composite1.fsh", "gl_FragData[0] = vec4(color, 1.0);",
         "gl_FragData[0] = vec4(cloud.rgb / max(cloud.a, 0.001), 1.0);"),
    ], scenes=cloud_scenes)
    clouds = {scene: mean(cloud_only, scene, masks[scene][0]) for scene in cloud_scenes}
    if clouds["clouds_night"] >= clouds["clouds"] * 0.25:
        raise RuntimeError(f"Clouds retain excessive radiance at night: {clouds}")
    night_control = variant("night-cloud-off", {"CLOUD_NIGHT_BRIGHTNESS": 0.0}, scenes=["clouds_night"])
    cloud_control_change = mean(baseline, "clouds_night", masks["clouds_night"][0]) - mean(
        night_control, "clouds_night", masks["clouds_night"][0])
    if cloud_control_change <= 1.0:
        raise RuntimeError("Night cloud control has no visible effect")

    result = {
        "bed_luminance": bed_brightness,
        "wool_luminance": wool_brightness,
        "night_bed_wool_ratio": night_ratio,
        "directional_shadow_relative_contrast": shadow_contrast,
        "local_shadow_luminance_gain": local_gain,
        "cloud_surface_luminance": clouds,
        "night_cloud_control_luminance_change": cloud_control_change,
    }
    (work / "verification.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2), flush=True)
    return result
