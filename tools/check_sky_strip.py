#!/usr/bin/env python3
"""Check periodic sky sampling without reading outside its packed atlas strip."""

import argparse
import json
from pathlib import Path

import moderngl
import numpy as np

from check_local_lighting import QUAD
from preview.shader_source import inline_shader, modernize


def main():
    """Exercise the production sampler around its longitude and atlas borders."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shader-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--observe", action="store_true")
    args = parser.parse_args()
    context = moderngl.create_standalone_context(require=450)
    source = inline_shader(args.shader_dir / "lib/sky.glsl", args.shader_dir)
    source += """
    void main() {
        float angle = (gl_FragCoord.x / 2048.0 - 0.5) * 0.08;
        float elevation = mix(-0.9, 0.9, gl_FragCoord.y / 128.0);
        vec3 direction = normalize(vec3(-cos(angle), elevation, sin(angle)));
        fullOut0 = sampleSkyStrip(skyLookupCoordinate(direction), 0.0);
    }
    """
    shader = context.program(vertex_shader=QUAD,
        fragment_shader="#version 450 core\n" + modernize(source, "fsh"))
    shader["colortex3"].value = 0
    output = context.texture((2048, 128), 4, dtype="f4")
    context.framebuffer([output]).use()
    context.viewport = (0, 0, 2048, 128)
    vao = context.vertex_array(shader, [])
    expected = np.array([0.4, 0.6, 0.8, 1.0], dtype="f4")
    report = {"renderer": context.info["GL_RENDERER"], "cases": []}
    for width, height in [(1280, 720), (1960, 1104), (983, 557)]:
        field = np.zeros((height, width, 4), dtype="f4")
        field[:height // 8, :width // 8] = expected
        # Neighbouring cache data must never participate in sky reconstruction.
        field[height // 8:height // 4, :width // 8] = (0.9, 0.05, 0.05, 0.5)
        texture = context.texture((width, height), 4, field.tobytes(), dtype="f4")
        texture.repeat_x = False
        texture.repeat_y = False
        texture.build_mipmaps()
        texture.use(0)
        shader["viewWidth"].value = width
        shader["viewHeight"].value = height
        for anisotropy, mipmaps in [(1, False), (8, False), (8, True)]:
            texture.filter = (moderngl.LINEAR_MIPMAP_LINEAR if mipmaps else moderngl.LINEAR,
                moderngl.LINEAR)
            texture.anisotropy = anisotropy
            vao.render(moderngl.TRIANGLES, vertices=3)
            values = np.frombuffer(output.read(), dtype="f4").reshape(128, 2048, 4)
            assert np.isfinite(values).all(), "Nonfinite sky strip sample"
            error = float(np.max(abs(values - expected)))
            report["cases"].append({"width": width, "height": height,
                "anisotropy": anisotropy, "mipmaps": mipmaps, "max_error": error})
            if not args.observe:
                # Allow hardware anisotropic-filter rounding well below one 8-bit step.
                assert error < 1e-3, "Sky sampling crosses the packed strip or longitude seam"
        texture.release()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
