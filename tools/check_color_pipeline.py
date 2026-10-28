#!/usr/bin/env python3
"""Run the production tone mapper and ambient-light functions on a local GPU.

Requires NumPy and ModernGL. Optional --baseline-shaders accepts an earlier
shader directory for direct middle-grey and ambient comparisons. Lightmap and
weather inputs are deterministic fixtures; this does not replace game images.
"""

import argparse
import colorsys
import json
from pathlib import Path
import re

import moderngl
import numpy as np

from check_glsl import FORMAT_TOKENS
from preview.source import expand


ROOT = Path(__file__).resolve().parents[1]
SHADERS = ROOT / "shaders"
LUMA = np.array([0.2126, 0.7152, 0.0722])
VERTEX = """#version 330
void main() {
    vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,
                  gl_VertexID == 2 ? 3.0 : -1.0);
    gl_Position = vec4(p, 0.0, 1.0);
}
"""
HEADER = "#version 330\n" + "".join(f"#define {name} 0\n" for name in FORMAT_TOKENS)


def function_source(path, name):
    """Extract complete production functions, preserving their actual bodies."""
    source = path.read_text(encoding="utf-8")
    match = re.search(r"\b(?:float|vec[234])\s+" + name + r"\s*\(", source)
    if match is None:
        raise ValueError(f"Missing GLSL function: {name}")
    cursor = source.index("{", match.start()) + 1
    nesting = 1
    while nesting:
        nesting += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[match.start():cursor]


class ColorProbe:
    """Compile current shader functions and read RGBA32F results without display clipping."""

    def __init__(self):
        self.context = moderngl.create_standalone_context(require=330)

    def draw(self, fragment, pixels, uniforms=None):
        """Supply linear HDR inputs and return exact floating point GPU output."""
        pixels = np.asarray(pixels, dtype=np.float32).reshape(-1, 3)
        source = self.context.texture((len(pixels), 1), 3, pixels.tobytes(), dtype="f4")
        source.use(0)
        program = self.context.program(vertex_shader=VERTEX, fragment_shader=fragment)
        if "probeInput" in program:
            program["probeInput"].value = 0
        for name, value in (uniforms or {}).items():
            if name in program:
                program[name].value = value
        geometry = self.context.vertex_array(program, [])
        target = self.context.simple_framebuffer((len(pixels), 1), components=4, dtype="f4")
        target.use()
        geometry.render(mode=moderngl.TRIANGLES, vertices=3)
        result = np.frombuffer(target.read(components=4, dtype="f4"), np.float32).reshape(-1, 4).copy()
        geometry.release()
        target.release()
        program.release()
        source.release()
        assert np.isfinite(result).all(), "Color pipeline produced NaN or infinity"
        return result[:, :3]

    def tonemap(self, pixels, shader_root=SHADERS, display=False, options=None, gamut=False):
        """Execute the same tone-mapping and display encoding used by final.fsh."""
        library = expand(shader_root / "lib/tonemap.glsl", shader_root)
        for name, value in (options or {}).items():
            library = re.sub(r"(^#define\s+" + name + r"\s+)\S+",
                             lambda found: found[1] + str(value), library, flags=re.M)
        operation = "fitDisplayGamut(color)" if gamut else "applyTonemap(color)"
        if display:
            operation = "toDisplaySpace(" + operation + ")"
        fragment = HEADER + library + """
uniform sampler2D probeInput;
out vec4 result;
void main() {
    vec3 color = texelFetch(probeInput, ivec2(gl_FragCoord.xy), 0).rgb;
    result = vec4(OPERATION, 1.0);
}
""".replace("OPERATION", operation)
        return self.draw(fragment, pixels)

    def ambient(self, lightmap_pixels, sky, sun, rain, shader_root=SHADERS, occlusion=1.0, sky_level=1.0):
        """Exercise real ambient functions with a fixed lightmap and zero extra GI."""
        settings = expand(shader_root / "settings.glsl", shader_root)
        common = expand(shader_root / "lib/common.glsl", shader_root)
        prerequisites = ("lib/uniforms.glsl", "lib/lightmap.glsl", "lib/weather.glsl")
        library = settings + common + "\n".join(expand(SHADERS / name, SHADERS) for name in prerequisites)
        lighting = shader_root / "lib/lighting.glsl"
        functions = ("getSunDirWorld", "getSunHeight", "getDayFactor", "getNightFactor",
                     "surfaceAmbient", "surfaceAmbientAt")
        stubs = """
vec3 companionBlockLight(vec3 p, vec3 n, vec2 lm, vec3 nativeLight) { return nativeLight; }
vec3 companionIndirect(vec3 p, vec3 n) { return vec3(0.0); }
vec3 twilightIrradiance(vec3 n) { return vec3(0.0); }
"""
        fragment = HEADER + library + stubs + "\n".join(function_source(lighting, name) for name in functions) + """
uniform vec2 probeLightmap;
uniform float probeOcclusion;
out vec4 result;
void main() {
    result = vec4(surfaceAmbientAt(probeLightmap, probeOcclusion,
                                   vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, -5.0)), 1.0);
}
"""
        # The production lightmap sampler decodes display RGB back to linear.
        texture = self.context.texture((16, 16), 3, np.asarray(lightmap_pixels, np.float32).tobytes(), dtype="f4")
        texture.use(1)
        values = {"lightmap": 1, "skyColor": sky, "sunPosition": (0.0, sun, 0.0),
                  "rainStrength": rain, "gbufferModelViewInverse": tuple(np.eye(4, dtype=np.float32).ravel()),
                  "probeLightmap": (0.03125, 0.03125 + sky_level * 0.9375),
                  "probeOcclusion": occlusion}
        result = self.draw(fragment, [[0.0, 0.0, 0.0]], values)[0]
        texture.release()
        return result


def check_tonemap(probe, baseline):
    """Check grey order, black, source hues, gamut fitting and all exposed curve modes."""
    levels = np.r_[0.0, np.geomspace(1e-8, 65504.0, 4095)]
    greys = np.repeat(levels[:, None], 3, axis=1)
    output = probe.tonemap(greys)
    display = probe.tonemap(greys, display=True)
    assert np.max(np.abs(output[0])) == 0.0, "Black point was lifted"
    assert np.max(np.abs(display[0])) == 0.0
    assert np.diff(output @ LUMA).min() >= -2e-6, "Linear grey ramp is not monotonic"
    assert np.diff(display @ LUMA).min() >= -2e-6, "Display grey ramp is not monotonic"
    assert np.max(np.ptp(output, axis=1)) < 2e-6, "Neutral grey acquired a color cast"

    hues = np.array([colorsys.hsv_to_rgb(hue, 0.95, 1.0) for hue in np.linspace(0.0, 1.0, 361)])
    sources = np.concatenate([hues * intensity for intensity in (0.02, 0.1, 0.4, 1.0, 4.0)])
    mapped = probe.tonemap(sources)
    input_hue = np.array([colorsys.rgb_to_hsv(*rgb)[0] for rgb in sources])
    output_hsv = np.array([colorsys.rgb_to_hsv(*rgb) for rgb in mapped])
    hue_error = np.abs(output_hsv[:, 0] - input_hue)
    hue_error = np.minimum(hue_error, 1.0 - hue_error) * 360.0
    visible = output_hsv[:, 1] > 0.05
    assert hue_error[visible].max() < 1.0, "Colored light hue changed by more than one degree"

    rng = np.random.default_rng(611)
    extreme = rng.uniform(-1000.0, 1000000.0, (2048, 3))
    for mode in (0, 1, 2):
        for saturation, contrast in ((0.8, 0.9), (1.0, 1.0), (1.25, 1.1)):
            result = probe.tonemap(extreme, options={"TONEMAP_MODE": mode, "SATURATION": saturation,
                                                    "CONTRAST": contrast, "EXPOSURE": 1.5})
            assert result.min() >= 0.0 and result.max() <= 1.0, "Display gamut escaped [0,1]"

    # A gamut mapper must preserve luminance while contracting chroma, including
    # negative channels caused by a user-selected saturation greater than one.
    wide = rng.uniform(-0.7, 1.7, (2048, 3))
    valid = (wide @ LUMA > 0.02) & (wide @ LUMA < 0.98)
    wide = wide[valid]
    fitted = probe.tonemap(wide, gamut=True)
    assert fitted.min() >= -2e-6 and fitted.max() <= 1.0 + 2e-6
    assert np.max(np.abs(fitted @ LUMA - wide @ LUMA)) < 2e-6

    middle = probe.tonemap([[0.18, 0.18, 0.18]])[0]
    report = {"grey_samples": len(levels), "colored_samples": len(sources),
              "maximum_hue_error_degrees": float(hue_error[visible].max()),
              "middle_grey_linear": float(middle @ LUMA),
              "middle_grey_display": float(probe.tonemap([[0.18] * 3], display=True)[0] @ LUMA)}
    if baseline:
        previous = probe.tonemap([[0.18] * 3], shader_root=baseline)[0]
        report["baseline_middle_grey_linear"] = float(previous @ LUMA)
        assert middle @ LUMA > previous @ LUMA * 1.15, "Middle grey did not become brighter"
    return report


def check_ambient(probe, baseline):
    """Check sky tint energy, rain continuity and unchanged sealed-cave illumination."""
    rows = np.linspace(0.0, 0.8, 16) ** (1.0 / 2.2)
    lightmap = np.repeat(np.repeat(rows[:, None, None], 16, axis=1), 3, axis=2)
    sky = (0.45, 0.65, 1.0)
    day = probe.ambient(lightmap, sky, 1.0, 0.0)
    rain = np.array([probe.ambient(lightmap, sky, 1.0, amount) for amount in np.linspace(0, 1, 17)])
    neutral_rain = rain[-1] / (rain[-1] @ LUMA)
    neutral_day = rain[0] / (rain[0] @ LUMA)
    assert np.ptp(neutral_rain) < np.ptp(neutral_day), "Rain tint became more chromatic"
    assert np.diff(rain @ LUMA).max() < 1e-5, "Rain increased diffuse-sky brightness"
    assert np.max(np.abs(np.diff(rain @ LUMA))) < 0.02, "Rain lighting has a discontinuity"

    black = np.zeros((16, 16, 3), dtype=np.float32)
    cave_day = probe.ambient(black, sky, 1.0, 0.0, sky_level=0.0)
    cave_night = probe.ambient(black, sky, -1.0, 1.0, sky_level=0.0)
    assert np.max(np.abs(cave_day - cave_night)) < 2e-6, "Weather/daylight leaked into a sealed cave"
    for sky_color in ((0.0, 0.0, 0.0), (1e-8, 1e-8, 1e-8), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0)):
        for sun in (1.0, -1.0):
            result = probe.ambient(lightmap, sky_color, sun, 0.5)
            assert result.min() >= 0.0 and result.max() < 8.0, "Unbounded ambient sky normalization"
    report = {"day_diffuse_luminance": float(day @ LUMA),
              "rain_diffuse_luminance": float(rain[-1] @ LUMA),
              "sealed_cave_luminance": float(cave_day @ LUMA)}
    if baseline:
        previous = probe.ambient(lightmap, sky, 1.0, 0.0, shader_root=baseline)
        old_cave = probe.ambient(black, sky, 1.0, 0.0, shader_root=baseline, sky_level=0.0)
        assert day @ LUMA > previous @ LUMA * 1.10
        assert np.max(np.abs(cave_day - old_cave)) < 2e-6
        report["baseline_day_diffuse_luminance"] = float(previous @ LUMA)
    return report


def main():
    """Write a reproducible GPU report with explicit numerical scope."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-shaders", type=Path)
    arguments = parser.parse_args()
    probe = ColorProbe()
    report = {"gpu": probe.context.info["GL_RENDERER"],
              "tonemap": check_tonemap(probe, arguments.baseline_shaders),
              "ambient": check_ambient(probe, arguments.baseline_shaders),
              "scope": "Production GLSL numeric checks with fixture inputs; not game image or FPS acceptance"}
    target = ROOT / ".check/color-pipeline/verification.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
