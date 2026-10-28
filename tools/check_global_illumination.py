#!/usr/bin/env python3
"""Run generated GI transport on a synthetic room using an actual GL context.

The fixture distinguishes surface reflection from free-space propagation, checks
sealed geometry and convergence, and exercises history at distant world origins.
It supplies synthetic data only to this standalone context, never to Minecraft.
"""
import argparse
import json
from pathlib import Path
import re

import moderngl
import numpy as np

from check_local_lighting import QUAD


def main():
    """Compare one surface bounce with recursive diffuse transport."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shader-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = (args.shader_dir / "prepare6.fsh").read_text(encoding="utf-8")
    source = re.sub(r"(^#define (?:SUNLIGHT_STRENGTH|MOONLIGHT_STRENGTH) )\S+",
                    r"\g<1>0.0", source, flags=re.M)
    context = moderngl.create_standalone_context(require=450)
    side = 32
    width = side * 8
    height = side * side // 16 + 1
    shape = (side, side // 2, side)
    voxels = np.zeros((shape[2], shape[1], shape[0]), dtype="u4")

    def solid(x, y, z, colour=(0.8, 0.8, 0.8), sky=0):
        """Pack the exact production opaque material layout."""
        rgb = np.rint(np.array(colour) * 255).astype(int)
        voxels[z, y, x] = (2 << 30) | (1 << 28) | (sky << 24) | int(rgb[0]) \
            | (int(rgb[1]) << 8) | (int(rgb[2]) << 16)

    for x in range(3, 29):
        for z in range(3, 29):
            solid(x, 2, z, sky=15)
            if not (7 <= x <= 11 and 7 <= z <= 11):
                solid(x, 12, z)
    for y in range(3, 12):
        for p in range(3, 29):
            solid(3, y, p, (0.8, 0.08, 0.03))
            solid(28, y, p)
            solid(p, y, 3)
            solid(p, y, 28)
        for z in range(4, 20):
            solid(16, y, z)
    # An inner closed room shares the bright fixture's air and thin walls.
    for x in range(20, 28):
        for y in range(3, 11):
            for z in range(20, 28):
                if x in (20, 27) or z in (20, 27) or y == 10:
                    solid(x, y, z)
    occupancy = context.texture((width, height - 1), 1, voxels.tobytes(), dtype="u4")
    occupancy.bind_to_image(5, read=True, write=False)
    empty = context.texture((width, height), 4, bytes(width * height * 16), dtype="f4")
    transmission = context.texture((width, height * 3), 4, dtype="f1")
    shadow = context.texture((2, 2), 1, np.ones((2, 2), dtype="f4").tobytes(), dtype="f4")
    fields = [context.texture((width, height * 6), 4, dtype="f2") for _ in range(2)]
    framebuffers = [context.framebuffer([field]) for field in fields]
    for unit, texture in enumerate((empty, empty, transmission, shadow)):
        texture.use(unit)
    samplers = {"colortex8": 0, "colortex10": 1, "colortex11": 2, "shadowtex0": 3, "colortex12": 4}

    def run(multiple, origin=(0, 0, 0), steps=160):
        """Iterate production shader code from a completely cleared history."""
        variant = re.sub(r"(^#define GI_MULTIBOUNCE )\d+", r"\g<1>" + str(int(multiple)), source, flags=re.M)
        program = context.program(vertex_shader=QUAD, fragment_shader=variant)
        quad = context.vertex_array(program, [])
        for name, unit in samplers.items():
            if name in program:
                program[name].value = unit
        for name in ("gbufferModelViewInverse", "shadowModelView", "shadowProjection"):
            if name in program:
                program[name].write(np.eye(4, dtype="f4").tobytes())
        for name, value in (("sunPosition", (0, 100, 0)), ("moonPosition", (0, -100, 0)),
                            ("shadowLightPosition", (0, 100, 0)),
                            ("cameraPosition", tuple(np.array(origin) + np.array(shape) / 2))):
            if name in program:
                program[name].value = value
        for field in fields:
            field.write(bytes(width * height * 6 * 8))
        previous = None
        tail_change = None
        for step in range(steps):
            fields[step % 2].use(4)
            framebuffers[1 - step % 2].use()
            context.viewport = (0, 0, width, height * 6)
            program["frameCounter"].value = step
            quad.render(vertices=3)
            if step in (steps - 21, steps - 1):
                data = np.frombuffer(fields[1 - step % 2].read(), dtype="f2").astype("f4")
                data = data.reshape(6, height * width, 4)[:, 2:2 + np.prod(shape)]
                data = data.reshape(6, shape[2], shape[1], shape[0], 4)
                if previous is not None:
                    tail_change = float(np.max(np.abs(data[..., :3] - previous[..., :3])))
                previous = data
        quad.release()
        program.release()
        return data, tail_change

    single, _ = run(False)
    multiple, tail = run(True)
    distant, _ = run(True, (-15000, 6000, 12000))
    interior = multiple[:, 21:27, 3:10, 21:27, :3]
    single_sum = float(single[..., :3].sum())
    multiple_sum = float(multiple[..., :3].sum())
    checks = {
        "finite_nonnegative": bool(np.isfinite(multiple).all() and np.min(multiple[..., :3]) >= 0),
        "nonzero_first_bounce": single_sum > 1.0,
        "additional_surface_bounces": multiple_sum > single_sum * 1.03,
        "sealed_room_dark": float(interior.max()) == 0.0,
        "bounded_radiance": float(multiple[..., :3].max()) < 2.0,
        "converged": tail < 0.002,
        "distant_origin_invariant": bool(np.array_equal(multiple, distant)),
    }
    report = {"renderer": context.info["GL_RENDERER"], "checks": checks,
              "single_energy": single_sum, "multiple_energy": multiple_sum,
              "sealed_peak": float(interior.max()), "tail_max_change": tail,
              "origin_max_delta": float(np.max(np.abs(multiple - distant))),
              "scope": "Generated production GLSL on standalone synthetic geometry; no Minecraft performance claim."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if not all(checks.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
