#!/usr/bin/env python3
"""Exercise production cloud bounds and horizon fading on a standalone GPU.

Requires NumPy and ModernGL. The fixture uses a constant noise texture to test
geometry, density bounds and continuity independently of a captured game frame.
It does not measure game performance or establish the final artistic appearance.
"""

import json
from pathlib import Path
import re

import moderngl
import numpy as np

from check_glsl import FORMAT_TOKENS
from preview.source import expand


ROOT = Path(__file__).resolve().parents[1]
SHADERS = ROOT / "shaders"


def production_function(path, name):
    """Read one complete production GLSL function without copying its formula."""
    source = path.read_text(encoding="utf-8")
    match = re.search(r"\bbool\s+" + name + r"\s*\(", source)
    if match is None:
        raise ValueError(f"Missing production function: {name}")
    opening = source.index("{", match.start())
    nesting = 1
    end = opening + 1
    while nesting:
        nesting += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


class CloudProbe:
    """Run the actual cloud density library against deterministic GPU inputs."""

    def __init__(self):
        self.context = moderngl.create_standalone_context(require=330)
        # The archived world-atlas branch names a generated layout include even
        # when disabled. Load the active prerequisites, then let GLSL eliminate
        # that inactive branch without requiring an obsolete generated atlas.
        dependencies = ("settings.glsl", "lib/uniforms.glsl", "lib/common.glsl", "lib/sky_noise.glsl")
        library = "\n".join(expand(SHADERS / name, SHADERS) for name in dependencies)
        density = (SHADERS / "lib/cloud_density.glsl").read_text(encoding="utf-8")
        library += re.sub(r'^\s*#include[^\n]*', '', density, flags=re.M)
        interval = production_function(SHADERS / "lib/clouds.glsl", "cloudRayInterval")
        header = "#version 330\n" + "".join(
            f"#define {name} 0\n" for name in FORMAT_TOKENS
        )
        vertex = """#version 330
            void main() {
                vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,
                              gl_VertexID == 2 ? 3.0 : -1.0);
                gl_Position = vec4(p, 0.0, 1.0);
            }
        """
        fragment = header + library.replace("texture2D(", "texture(") + interval + """
            uniform int probeMode;
            uniform vec3 probeOrigin;
            uniform vec3 probeRay;
            uniform float probeLimit;
            out vec4 result;
            void main() {
                float radius = cloudRenderDistance();
                if (probeMode == 0) {
                    float entry;
                    float exit;
                    bool hit = cloudRayInterval(probeOrigin, probeRay, probeLimit, entry, exit);
                    result = vec4(entry, exit, hit ? 1.0 : 0.0, radius);
                } else {
                    float distance = (gl_FragCoord.x - 0.5) / 255.0 * radius * 1.2;
                    vec2 altitude = cloudAltitudeBounds();
                    float height = mix(altitude.x, altitude.y, gl_FragCoord.y / 128.0);
                    vec3 world = cameraPosition + vec3(distance, height - cameraPosition.y, 0.0);
                    result = vec4(cloudHorizonVisibility(world), cloudDensity(world, true),
                                  radius, CLOUD_DENSITY);
                }
            }
        """
        self.program = self.context.program(vertex_shader=vertex, fragment_shader=fragment)
        self.geometry = self.context.vertex_array(self.program, [])
        noise = np.ones((1024, 1024, 4), dtype=np.float32)
        self.noise = self.context.texture((1024, 1024), 4, noise.tobytes(), dtype="f4")
        self.noise.use(0)
        self.program["noisetex"].value = 0
        self.program["cameraPosition"].value = (0.0, 64.0, 0.0)
        self.program["rainStrength"].value = 0.0
        self.program["frameTimeCounter"].value = 0.0

    def render(self, mode, size=(1, 1), **uniforms):
        """Read floating point output, rejecting nonfinite bounds or density."""
        self.program["probeMode"].value = mode
        for name, value in uniforms.items():
            self.program[name].value = value
        target = self.context.simple_framebuffer(size, components=4, dtype="f4")
        target.use()
        self.geometry.render(mode=moderngl.TRIANGLES, vertices=3)
        result = np.frombuffer(target.read(components=4, dtype="f4"), dtype=np.float32)
        result = result.reshape(size[1], size[0], 4).copy()
        target.release()
        assert np.isfinite(result).all(), "Nonfinite cloud output"
        return result


def main():
    """Check grazing, zenith, reflected origins and continuous finite density."""
    probe = CloudProbe()
    rows = []
    for draw_distance in (64.0, 192.0, 384.0, 1024.0):
        density = probe.render(1, size=(256, 128), far=draw_distance)
        visibility = density[0, :, 0]
        radius = float(density[0, 0, 2])
        cloud_density = density[..., 1]
        assert visibility[0] == 1.0
        assert visibility[-1] == 0.0
        assert np.max(np.diff(visibility)) <= 1e-6, "Horizon fade reverses direction"
        assert np.max(np.abs(np.diff(visibility))) < 0.025, "Horizon has a hard edge"
        assert np.max(cloud_density[:, :80]) > 0.1, "Nearby clouds were removed"
        assert np.max(cloud_density[:, 214:]) == 0.0, "Clouds survive beyond the horizon"
        assert np.all(cloud_density <= density[..., 0] * density[..., 3] + 1e-5)

        # Known rays cover the exact horizon, just above it, vertical views from
        # both sides, an in-cloud grazing ray, and displaced reflection origins.
        cases = [
            ((0.0, 64.0, 0.0), (1.0, 0.0, 0.0), False),
            ((0.0, 64.0, 0.0), (1.0, 0.001, 0.0), False),
            ((0.0, 64.0, 0.0), (0.0, 1.0, 0.0), True),
            ((0.0, 1000.0, 0.0), (0.0, -1.0, 0.0), True),
            ((0.0, 300.0, 0.0), (1.0, 0.0, 0.0), True),
            ((radius * 0.1, 300.0, 0.0), (1.0, 0.0, 0.0), True),
            ((radius * 1.1, 300.0, 0.0), (-1.0, 0.0, 0.0), True),
            ((radius * 1.1, 300.0, 0.0), (1.0, 0.0, 0.0), False),
            ((radius * 1.1, 64.0, 0.0), (0.0, 1.0, 0.0), False),
        ]
        for origin, direction, expected_hit in cases:
            ray = np.array(direction, dtype=float)
            ray /= np.linalg.norm(ray)
            entry, exit, hit, _ = probe.render(
                0, far=draw_distance, probeOrigin=origin,
                probeRay=tuple(ray), probeLimit=6000.0
            )[0, 0]
            assert bool(hit) == expected_hit, (draw_distance, origin, direction, entry, exit)
            if not expected_hit:
                continue
            assert 0.0 <= entry < exit <= 6000.01
            points = np.array(origin) + ray * np.linspace(entry + 0.001, exit - 0.001, 16)[:, None]
            assert np.max(np.linalg.norm(points[:, (0, 2)], axis=1)) <= radius + 0.01
            assert points[:, 1].min() >= 131.2 - 0.01
            assert points[:, 1].max() <= 620.8 + 0.01

        # A terrain intersection before cloud entry must continue to block it.
        blocked = probe.render(
            0, far=draw_distance, probeOrigin=(0.0, 64.0, 0.0),
            probeRay=(0.0, 1.0, 0.0), probeLimit=40.0
        )[0, 0]
        assert blocked[2] == 0.0
        rows.append({"terrain_far": draw_distance, "cloud_radius": radius,
                     "maximum_density": float(cloud_density.max())})

    assert all(a["cloud_radius"] <= b["cloud_radius"] for a, b in zip(rows, rows[1:]))
    assert rows[-1]["cloud_radius"] <= 6000.0
    report = {"gpu": probe.context.info["GL_RENDERER"], "cases": rows,
              "scope": "Production GLSL geometry and density; not a game visual or FPS test"}
    output = ROOT / ".check/cloud-horizon"
    output.mkdir(parents=True, exist_ok=True)
    (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
