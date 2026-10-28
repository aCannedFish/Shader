#!/usr/bin/env python3
"""Check production POM against a constant-depth plane and atlas bounds."""
import argparse
import json
from pathlib import Path

import moderngl
import numpy as np

from check_local_lighting import QUAD
from preview.shader_source import inline_shader, modernize


def main():
    """Exercise actual assembled GLSL; synthetic data remains outside Minecraft."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shader-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    context = moderngl.create_standalone_context(require=450)
    source = inline_shader(args.shader_dir / "lib/pbr_surface.glsl", args.shader_dir)
    source += """
    uniform float fixtureDistance;
    uniform vec4 fixtureTile;
    void main() {
        vec2 uv = vec2(0.2) + gl_FragCoord.xy / vec2(128.0) * 0.6;
        vec3 position = vec3((uv * 2.0 - 1.0) * fixtureDistance, -fixtureDistance);
        vec2 result = pbrParallaxUv(uv, position, vec3(0.0, 0.0, 1.0), fixtureTile);
        fullOut0 = vec4(result, uv);
    }
    """
    shader = context.program(vertex_shader=QUAD,
        fragment_shader="#version 450 core\n" + modernize(source, "fsh"))
    shader["normals"].value = 0
    shader["fixtureDistance"].value = 1
    shader["fixtureTile"].value = (0.5, 0.5, 0.5, 0.5)
    values = np.ones((64, 64, 4), dtype="f4")
    texture = context.texture((64, 64), 4, values.tobytes(), dtype="f4")
    texture.use(0)
    output = context.texture((128, 128), 4, dtype="f4")
    context.framebuffer([output]).use()
    context.viewport = (0, 0, 128, 128)
    vao = context.vertex_array(shader, [])

    def render():
        vao.render(moderngl.TRIANGLES, vertices=3)
        result = np.frombuffer(output.read(), dtype="f4").reshape(128, 128, 4).copy()
        assert np.isfinite(result).all()
        return result

    flat = render()
    assert np.max(abs(flat[..., :2] - flat[..., 2:])) < 1e-6, "Flat map moves UV"
    values[..., 3] = 128 / 255
    texture.write(values.tobytes())
    plane = render()
    expected = plane[..., 2:] + (plane[..., 2:] * 2 - 1) * 0.25 * (127 / 255)
    error = float(np.max(abs(plane[..., :2] - expected)))
    assert error < 1e-5, "POM disagrees with constant-depth planar intersection"
    assert np.max(abs(plane[..., :2] - plane[..., 2:])) > 0.03
    shader["fixtureTile"].value = (0, 0, 0, 0)
    invalid = render()
    assert np.max(abs(invalid[..., :2] - invalid[..., 2:])) < 1e-6
    shader["fixtureTile"].value = (0.5, 0.5, 0.3, 0.3)
    bounded = render()
    assert bounded[..., :2].min() >= 0.2 and bounded[..., :2].max() <= 0.8
    shader["fixtureDistance"].value = 100
    distant = render()
    assert np.max(abs(distant[..., :2] - distant[..., 2:])) < 1e-6
    report = {"renderer": context.info["GL_RENDERER"], "planar_intersection_error_uv": error,
        "flat_map_unchanged": True, "invalid_tile_unchanged": True,
        "atlas_bounds_preserved": True, "distance_limit_applied": True,
        "scope": "Standalone production GLSL with synthetic textures; not native visual acceptance"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
