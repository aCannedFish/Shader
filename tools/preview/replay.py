"""Index real GPU recordings, replace compatible shaders, and export a report.

Replay executes captured draw calls with current converted shader programs.
Capture-owned configuration and shader interfaces are checked before replacement
so unsupported structural changes fail instead of producing misleading previews.
"""

from bisect import bisect_left
import html
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

from .runtime import calls
from .source import (
    COMMENT, digest, generate, host_configuration, normalized, shader_snapshot,
)

SCENES = (
    "perf_static", "perf_walk", "perf_edits",
    "reflect_corner", "reflect_quartz", "reflect_wall", "reflect_wall_glass",
    "reflect_obsidian", "reflect_portal",
    "reflect_corner_shadow_off", "reflect_corner_matte",
    "seam_room", "seam_room_shadow_off", "seam_room_gi_off", "seam_room_matte", "seam_room_native",
    "scale_air_100", "scale_air_050", "scale_air_067", "scale_air_075",
    "scale_air_117", "scale_air_150", "scale_air_200", "scale_air_reset",
    "scale_water_050", "scale_water_200",
    "colour_roof_clear", "colour_roof_red", "colour_roof_blue",
    "colour_range_far", "colour_range_middle", "colour_range_near",
    "colour_update_red", "colour_room_photo",
    "colour_wrap_origin", "colour_wrap_positive", "colour_wrap_negative", "colour_wrap_z", "colour_wrap_sun",
    "colour_user_grass", "colour_user_quartz",
    "colour_torch", "colour_soul", "colour_redstone", "colour_sea", "colour_dark",
    "colour_glass_clear", "colour_glass_red", "colour_glass_blue", "colour_glass_stack",
    "colour_glass_mixed", "colour_glass_pane", "colour_glass_opaque",
    "colour_sun_clear", "colour_sun_red", "colour_sun_blue",
    *("stability_air_sequence_" + str(index) for index in range(6)),
    *("stability_water_sequence_" + str(index) for index in range(6)),
    "caustics_pool_day", "caustics_pool_night", "visibility_cave_day", "visibility_cave_night",
    "lens_sun_open", "lens_sun_blocked", "lens_sun_behind",
    "lens_sun_lowview",
    "shadow_path_sunset", "shadow_path_motion", "shadow_path_late", "shadow_path_noon",
    "shadow_path_photo",
    "sunshafts_sunrise", "sunshafts_sunrise_motion", "sunshafts_sunset",
    "sunshafts_oblique", "sunshafts_oblique_motion",
    "sunshafts_noon", "sunshafts_night", "sunshafts_room",
    "lighting_gi_room", "lighting_gi_two_lights",
    "rim_sunset", "rim_sunset_late", "rim_night", "rim_sunrise_early", "rim_sunrise", "rim_day",
    "rim_user_north", "rim_user_west", "rim_user_east", "rim_user_south",
    "style_village_night", "style_village_day", "style_village_ground",
    "sky_sun", "sky_sunrise", "sky_sunset", "sky_moon", "sky_moon_quarter", "sky_moon_new",
    "sky_zenith", "sky_nadir",
    "lighting_bed_day", "lighting_bed_night", "lighting_bed_lit",
    "lighting_shadow_day_dark", "lighting_shadow_day_lit",
    "lighting_shadow_sunrise_dark", "lighting_shadow_sunset_dark",
    "lighting_shadow_night_dark", "lighting_shadow_night_lit", "clouds_night",
    "sky_direction_0", "sky_direction_45", "sky_direction_90", "sky_direction_135", "sky_direction_180", "sky_direction_225", "sky_direction_270", "sky_direction_315",
    "daylight", "sunset", "night", "water", "underwater", "clouds", "fog",
    "water_shallow", "water_depth_steps",
    "water_grazing", "water_grazing_motion",
    "water_glitter", "water_glitter_late",
    "weather_clear", "weather_water_clear", "weather_water_rain", "weather_water_splash",
    "weather_rain_start", "weather_rain", "weather_drying",
    "weather_night", "weather_snow", "weather_forest_clear", "weather_forest_rain",
    "weather_mountain_rain",
    "weather_village_rain", "weather_village_ground",
    "water_depth_steps_motion", "underwater_interface_motion",
    "underwater_shafts_noon", "underwater_shafts_morning", "underwater_shafts_night", "underwater_cave",
    "cloud_below", "cloud_inside", "cloud_above", "cloud_motion",
    "migration_warm_north", "migration_warm_east", "migration_warm_south", "migration_warm_west",
    "migration_world_north", "migration_world_east", "migration_world_south",
    "migration_world_west", "migration_world_room",
    "migration_wrap_origin", "migration_wrap_positive", "migration_wrap_negative",
    "migration_wrap_z", "migration_wrap_large", "migration_wrap_return",
    "migration_reload", "water_reflection", "water_reflection_motion", "water_cave_dark",
    "water_cave_lit", "water_cave_night", "water_glass",
    "trans_water_open", "trans_water_window", "trans_water_tinted",
    "trans_underwater_open", "trans_underwater_glass", "water_edge_left", "water_edge_right",
    "local_shadow_dark", "local_shadow_lit", "local_light_night",
    "atmos_forest_dawn", "atmos_forest_sunrise", "atmos_forest_noon", "atmos_forest_night",
    "atmos_mountain", "atmos_aurora_north", "atmos_aurora_rain", "atmos_aurora_water", "ore_glow_gallery", "ore_glow_closeup",
    "nether_atmosphere", "end_atmosphere", "end_void",
    "material_day", "material_night", "material_glass",
    "nether_materials", "nether_night", "end_materials", "end_night",
    "foliage_backlit", "foliage_frontlit", "foliage_night",
    "vegetation", "vegetation_motion", "vegetation_roots", "vegetation_shadows",
    "underwater_shallow", "underwater_deep", "underwater_deep_down", "underwater_air", "underwater_air_deep",
    "underwater_interface",
    "underwater_magma_dark", "underwater_magma_lit", "water_far",
)


def interfaces(source):
    """Compare declared vertex inputs, varyings, outputs, uniforms and samplers."""
    text = COMMENT.sub("", source)
    declarations = re.findall(r"^\s*(?:uniform|in|out|attribute|varying)\s+[^;\n]+;", text, re.MULTILINE)
    # 重复展开的 include guard 不会产生新的 GL 接口，比较唯一声明即可。
    return sorted({re.sub(r"\s+", "", line) for line in declarations})


def dump_selected(runtime, trace, functions):
    """Inspect only relevant GPU function names, avoiding large buffer dumps."""
    return subprocess.check_output([
        runtime["apitrace"], "dump", "--color=never", "--multiline=no",
        f"--grep={functions}", str(trace),
    ], text=True)


def render_quality_source(source, quality=None):
    """Separate the loader's render-quality header from otherwise identical code."""
    return re.sub(r'^#define MC_RENDER_QUALITY[^\n]*',
                  quality or '#define MC_RENDER_QUALITY <capture>', source, flags=re.MULTILINE)


def index_capture(root, runtime, converter):
    """Map exported source files and screenshot readbacks to the GPU recording."""
    from PIL import Image

    trace = root / ".preview" / "captures" / "minecraft.trace"
    snapshot = shader_snapshot(root)
    captured_shaders = root / ".preview" / "game" / "shaderpacks" / "SimpleShader" / "shaders"
    # Validate the immutable source copy used by the client, so ordinary edits
    # made during capture are still eligible for later offline replacement.
    generate(root, converter, snapshot, root / ".preview" / "index-generated",
             verify=True, shader_root=captured_shaders)
    dump = dump_selected(runtime, trace, "^(glShaderSource|glAttachShader|glLinkProgram|glReadPixels|CGLFlushDrawable|glTexImage2D|glGetError)$")
    ids = [int(line.split()[0]) for line in dump.splitlines() if "glShaderSource(" in line]
    exported = root / ".preview" / "game" / "shaderpacks" / "debug" / "shaders"
    sources = {name: (exported / name).read_text() for name in snapshot}
    source_names = {}
    for name, source in sources.items():
        key = normalized(render_quality_source(source))
        source_names.setdefault(key, []).append(name)
    programs = []
    ambiguous = []
    shader_calls = {}
    candidates_by_call = {}
    sources_by_call = {}
    for call in calls(runtime, trace, ",".join(map(str, ids))):
        arguments = dict(call[3])
        strings = arguments["string"]
        if len(strings) != 1 or arguments["length"] != 0:
            continue
        source = strings[0]
        shader_calls.setdefault(arguments['shader'], []).append(call[0])
        sources_by_call[call[0]] = source
        candidates = source_names.get(normalized(render_quality_source(source)), [])
        candidates_by_call[call[0]] = candidates
        hint = re.search(r"(?:world-?\d+/)?(?:gbuffers_\w+|shadow|deferred\d*|composite\d*|final)\.(?:vsh|fsh)", source)
        matches = candidates
        exact = [name for name in candidates
                 if render_quality_source(sources[name]).strip() == render_quality_source(source).strip()]
        if len(exact) == 1:
            matches = exact
        elif len(candidates) > 1 and hint:
            matches = [name for name in candidates if name == hint.group(0)]
        if len(matches) == 1:
            name = matches[0]
            programs.append({"call": call[0], "name": name, "source": source,
                             "interfaces": interfaces(source)})
        elif matches:
            ambiguous.append((call[0], source, matches))
    # Reloads can produce many identical vertex shaders without filename hints.
    # Their actual linked fragment stage identifies the matching entry point.
    indexed = {program['call']: program for program in programs}
    attached = {}
    for line in dump.splitlines():
        attach = re.match(r'(\d+) glAttachShader\(program = (\d+), shader = (\d+)\)', line)
        if attach:
            number, program, shader = map(int, attach.groups())
            history = shader_calls.get(shader, [])
            index = bisect_left(history, number) - 1
            if index >= 0:
                attached.setdefault(program, []).append(history[index])
        link = re.match(r'\d+ glLinkProgram\(program = (\d+)\)', line)
        if not link:
            continue
        stages = attached.pop(int(link[1]), [])
        # Dimension folders can have identical discard-only fragments. The
        # linked vertex stage still identifies which world entry owns the call.
        vertices = [indexed[number]['name'] for number in stages
                    if number in indexed and indexed[number]['name'].endswith('.vsh')]
        if len(vertices) == 1:
            fragment = vertices[0].replace('.vsh', '.fsh')
            for number in stages:
                if fragment not in candidates_by_call.get(number, []):
                    continue
                if number in indexed:
                    indexed[number]['name'] = fragment
                else:
                    source = sources_by_call[number]
                    entry = {'call': number, 'name': fragment, 'source': source,
                             'interfaces': interfaces(source)}
                    programs.append(entry)
                    indexed[number] = entry
        fragments = [indexed[number]['name'] for number in stages
                     if number in indexed and indexed[number]['name'].endswith('.fsh')]
        if len(fragments) != 1:
            continue
        vertex = fragments[0].replace('.fsh', '.vsh')
        for number in stages:
            if number in indexed or vertex not in candidates_by_call.get(number, []):
                continue
            source = sources_by_call[number]
            entry = {'call': number, 'name': vertex, 'source': source, 'interfaces': interfaces(source)}
            programs.append(entry)
            indexed[number] = entry
    # Identical fullscreen code may lack a filename comment. Resolve it only
    # when all other candidates are already identified and one call remains.
    missing = sorted(set(snapshot) - {program["name"] for program in programs})
    for name in missing[:]:
        candidates = [(call, source) for call, source, names in ambiguous if name in names]
        if len(candidates) == 1 and all(
                candidate == name or candidate not in missing
                for _, _, names in ambiguous if name in names for candidate in names):
            call, source = candidates[0]
            programs.append({"call": call, "name": name, "source": source,
                             "interfaces": interfaces(source)})
            missing.remove(name)
    if missing:
        raise RuntimeError("Could not uniquely map shaders to capture: " + ", ".join(missing))

    baseline = root / ".preview" / "game" / "screenshots"
    capture_meta = json.loads((root / ".preview" / "capture.json").read_text())
    expected_scenes = tuple(capture_meta.get("scenes") or SCENES)
    # Java 按场景表执行；新增镜头时 Python 选项表的顺序可能不同。
    # 以本次客户端实际打印的执行顺序匹配像素读回，拒绝缺失或重复镜头。
    capture_log = root / ".preview" / "captures" / "capture.log"
    if capture_log.exists():
        log_text = re.sub(r"\x1b\[[0-9;]*m", "", capture_log.read_text(errors="replace"))
        logged_scenes = re.findall(r"^SIMPLE_PREVIEW scene (\w+)\s*$", log_text, re.MULTILINE)
        if logged_scenes:
            if len(logged_scenes) != len(expected_scenes) or set(logged_scenes) != set(expected_scenes):
                raise RuntimeError("Capture log does not contain each requested scene exactly once")
            expected_scenes = tuple(logged_scenes)
    size = Image.open(baseline / (expected_scenes[0] + ".png")).size
    readbacks = []
    frames = []
    expected_errors = []
    previous_proxy = None
    for line in dump.splitlines():
        if "CGLFlushDrawable(" in line:
            frames.append(int(line.split()[0]))
        elif "glReadPixels(" in line and "format = GL_RGBA" in line:
            if f"width = {size[0]}, height = {size[1]}" in line:
                readbacks.append(int(line.split()[0]))
        elif "glTexImage2D(" in line:
            previous_proxy = int(line.split()[0]) if "GL_PROXY_TEXTURE_2D" in line else None
        elif "glGetError() = GL_INVALID_VALUE" in line and previous_proxy is not None:
            expected_errors.append(previous_proxy)
            previous_proxy = None
    if len(readbacks) != len(expected_scenes):
        raise RuntimeError(f"Expected {len(expected_scenes)} scene readbacks, found {len(readbacks)}")
    scenes = []
    for name, readback in zip(expected_scenes, readbacks):
        frame = bisect_left(frames, readback)
        scenes.append({"name": name, "call": readback, "frame": frame,
                       "baseline": str(baseline / f"{name}.png")})
    manifest = {
        "trace": str(trace), "trace_sha256": digest(trace),
        "programs": programs, "snapshot": snapshot, "scenes": scenes,
        "host_configuration": host_configuration(captured_shaders),
        "image_size": list(size), "loader_sha256": converter["loader_sha256"],
        "expected_error_calls": expected_errors,
    }
    path = root / ".preview" / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
    print(f"Indexed {len(programs)} shader programs and {len(scenes)} scenes", flush=True)
    return manifest


def replace_programs(runtime, manifest, generated, output):
    """Replace changed shader strings in one pass through the binary recording."""
    replacements = []
    selected = []
    replacement_sources = {}
    for index, program in enumerate(manifest["programs"]):
        source = generated[program["name"]]
        quality = re.search(r'^#define MC_RENDER_QUALITY[^\n]*', program["source"], re.MULTILINE)
        if quality:
            source = render_quality_source(source, quality.group(0))
        if normalized(source) == normalized(program["source"]):
            continue
        if interfaces(source) != sorted(set(program["interfaces"])):
            raise RuntimeError(f"Shader interface changed; recapture required: {program['name']}")
        before = output / f"before-{index}.glsl"
        after = output / f"after-{index}.glsl"
        before.write_text(program["source"])
        after.write_text(source)
        expression = f"s|@file({before})|@file({after})|"
        replacements.extend(("-e", expression))
        selected.append(program["call"])
        replacement_sources[program["call"]] = source
    original = Path(manifest["trace"])
    if not selected:
        return original, 0
    changed = output / "modified.trace"
    subprocess.run([
        runtime["apitrace"], "sed", "--calls=" + ",".join(map(str, selected)),
        *replacements, "-o", str(changed), str(original),
    ], check=True, stdout=subprocess.DEVNULL)
    # Verify serialized replacement source, including non-truncated lengths.
    replacement_calls = {call[0]: dict(call[3])["string"][0]
                         for call in calls(runtime, changed, ",".join(map(str, selected)))}
    for program in manifest["programs"]:
        if program["call"] in replacement_calls:
            if replacement_calls[program["call"]] != replacement_sources[program["call"]]:
                raise RuntimeError(f"GPU source replacement failed: {program['name']}")
    return changed, len(selected)


def render(root, runtime, converter, names=None, shader_root=None, output=None):
    """Publish success or a visible error page, never an unlabeled stale result."""
    destination = (output or root / ".preview" / "latest").resolve()
    try:
        result = _render(root, runtime, converter, names, shader_root, destination)
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        destination.mkdir(parents=True, exist_ok=True)
        message = html.escape(str(error))
        page = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>预览失败</title><style>body{{background:#101820;color:#edf3f7;font:16px system-ui;margin:32px}}</style>
<h1>预览失败</h1><p>{message}</p><p>当前源码未生成有效图片。请检查终端输出和 replay.log。</p></html>'''
        (destination / "index.html").write_text(page)
        (destination / "failure.txt").write_text(str(error))
        raise
    failure = destination / "failure.txt"
    if failure.exists():
        failure.unlink()
    return result


def _render(root, runtime, converter, names=None, shader_root=None, output=None):
    """Replay selected scenes and export PNGs, difference metrics and a gallery."""
    manifest = json.loads((root / ".preview" / "manifest.json").read_text())
    if digest(Path(manifest["trace"])) != manifest["trace_sha256"]:
        raise RuntimeError("GPU recording changed; run index again before replay")
    shader_root = (shader_root or root / "shaders").resolve()
    if host_configuration(shader_root) != manifest["host_configuration"]:
        raise RuntimeError("Loader-owned configuration changed; capture a new scene recording")
    if converter["loader_sha256"] != manifest["loader_sha256"]:
        raise RuntimeError("OptiFine loader changed; recapture required")
    scene_names = set(names or [scene["name"] for scene in manifest["scenes"]])
    scenes = [scene for scene in manifest["scenes"] if scene["name"] in scene_names]
    if len(scenes) != len(scene_names):
        raise RuntimeError("Unknown scene requested")
    output = (output or root / ".preview" / "latest").resolve()
    output.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    generated = generate(root, converter, manifest["snapshot"], output / "programs", shader_root=shader_root)
    trace, replaced = replace_programs(runtime, manifest, generated, output)
    target = output / "selected.trace"
    last = max(scene["call"] for scene in scenes)
    subprocess.run([
        runtime["apitrace"], "trim", f"--calls=0-{last}", "-o", str(target), str(trace),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = output / "replay.log"
    prefix = output / "frame-"
    with log.open("w") as stream:
        result = subprocess.run([
            runtime["glretrace"], "--singlethread", "--headless", "-S",
            ",".join(str(scene["call"]) for scene in scenes), "-s", str(prefix), str(target),
        ], stdout=stream, stderr=subprocess.STDOUT, timeout=240)
    errors = log.read_text(errors="replace")
    unexpected = []
    for line in errors.splitlines():
        if not re.search(r"compilation failed|link failed|error:|GL_INVALID_", line, re.IGNORECASE):
            continue
        match = re.match(r"(\d+):.*glGetError\(glTexImage2D\) = GL_INVALID_VALUE", line)
        if match and int(match.group(1)) in manifest.get("expected_error_calls", []):
            continue
        unexpected.append(line)
    if result.returncode != 0 or unexpected:
        raise RuntimeError(f"GPU replay failed; inspect {log}")
    for scene in scenes:
        image = output / f"frame-{scene['call']:010d}.png"
        if not image.exists():
            raise RuntimeError(f"Missing replay image: {image}")
        shutil.copy2(image, output / f"{scene['name']}.png")
    report = {
        "seconds": round(time.perf_counter() - started, 3), "replaced_programs": replaced,
        "scenes": scenes, "shader_root": str(shader_root), "image_size": manifest["image_size"],
    }
    write_report(output, report)
    print(f"Rendered {len(scenes)} scenes in {report['seconds']} s; replaced {replaced} programs", flush=True)
    return report


def write_report(output, report):
    """Create comparisons and a local gallery without uploading captured assets."""
    from PIL import Image, ImageChops, ImageDraw, ImageStat

    cards = []
    sheet = Image.new("RGB", (960, 304 * ((len(report["scenes"]) + 1) // 2)), "#101820")
    painter = ImageDraw.Draw(sheet)
    for index, scene in enumerate(report["scenes"]):
        name = scene["name"]
        baseline = Image.open(scene["baseline"]).convert("RGB")
        current = Image.open(output / f"{name}.png").convert("RGB")
        if baseline.size != current.size:
            raise RuntimeError(f"Replay image dimensions differ: {name}")
        difference = ImageChops.difference(baseline, current)
        scene["mean_error"] = round(sum(ImageStat.Stat(difference).mean) / 3, 6)
        scene["changed_pixels"] = sum(pixel != (0, 0, 0) for pixel in difference.get_flattened_data())
        baseline.save(output / f"{name}-baseline.png")
        difference.save(output / f"{name}-diff.png")
        thumbnail = current.copy()
        thumbnail.thumbnail((464, 261))
        x, y = (index % 2) * 480 + 8, (index // 2) * 304 + 30
        sheet.paste(thumbnail, (x, y))
        painter.text((x, y - 20), name, fill="white")
        cards.append(f'''<article><h2>{html.escape(name)}</h2>
<img src="{name}.png" alt="{name}">
<details><summary>基准与差异</summary><img src="{name}-baseline.png" alt="baseline">
<img src="{name}-diff.png" alt="difference"></details>
<p>变化像素 {scene['changed_pixels']:,} · 平均通道差 {scene['mean_error']}</p></article>''')
    sheet.save(output / "overview.png")
    page = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>Shader 预览</title><style>
body{{margin:24px;background:#101820;color:#edf3f7;font:16px system-ui}}
h1{{font-size:24px}}main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(440px,1fr));gap:20px}}
article{{background:#192630;padding:16px;border-radius:8px}}h2{{font-size:18px}}img{{width:100%;height:auto}}
p,summary{{color:#bdcbd6}}summary{{cursor:pointer}}</style>
<h1>Shader 预览</h1><p>{len(report['scenes'])} 个场景 · {report['seconds']} 秒 ·
替换 {report['replaced_programs']} 个程序</p><main>{''.join(cards)}</main></html>'''
    (output / "index.html").write_text(page)
    (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
