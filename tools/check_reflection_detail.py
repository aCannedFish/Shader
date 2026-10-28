#!/usr/bin/env python3
"""Check the production reflection detail guards in an isolated GL fixture."""
import argparse
import json
from pathlib import Path
import moderngl
import numpy as np
from check_local_lighting import PREAMBLE, QUAD, production


def function_source(path, name):
    """Extract one unchanged production function with balanced braces."""
    source = path.read_text(encoding="utf-8")
    first = source.index("vec4 " + name + "(")
    opening = source.index("{", first)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[first:end]


def main():
    """Same-surface colour is allowed; other cells and transparent carriers are rejected."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    context = moderngl.create_standalone_context(require=450)
    declarations = """
    uniform mat4 shadowProjection, shadowModelView, shadowProjectionInverse, shadowModelViewInverse;
    uniform sampler2D shadowtex0, shadowtex1, shadowcolor0;
    const float EPSILON = 0.00001;
    vec3 viewToAbsoluteWorld(vec3 p) { return p + cameraPosition; }
    vec3 distortShadow(vec3 p) { return p; }
    vec2 undistortShadow(vec2 p) { return p; }
    vec2 shadowTexelCenter(vec2 uv) { return (floor(uv * 8.0) + 0.5) / 8.0; }
    float shadowDepthToBlocks(float d) { return d * 2.0; }
    vec3 toLinearSpace(vec3 c) { return c; }
    """
    source = PREAMBLE + declarations + production("shaders/lib/conventional_lpv.glsl")
    source += "\n" + function_source(Path("shaders/lib/reflection_occlusion.glsl"), "refineReflectionVoxelMaterial")
    source += """
    layout(location=0) out vec4 result;
    void main() {
        result = refineReflectionVoxelMaterial(vec4(0.4, 0.4, 0.4, 1.0),
            vec3(0.0), vec3(1.0, 0.0, 0.0), 3.5);
    }
    """
    shader = context.program(vertex_shader=QUAD, fragment_shader=source)
    shader["cameraPosition"].value = (16.5, 8.5, 16.5)
    matrices = {"gbufferModelViewInverse": np.eye(4), "shadowProjection": np.diag([0.25, 1, 1, 1]),
        "shadowProjectionInverse": np.diag([4, 1, 1, 1]), "shadowModelView": np.eye(4),
        "shadowModelViewInverse": np.eye(4)}
    matrices["shadowModelView"][1, 3] = -0.125
    matrices["shadowModelViewInverse"][1, 3] = 0.125
    for name, matrix in matrices.items():
        shader[name].write(np.asarray(matrix.T, dtype="f4").tobytes())
    voxels = np.zeros((32, 16, 32), dtype="u4")
    voxels[16, 8, 20] = (2 << 30) | (1 << 28) | 128 | (128 << 8) | (128 << 16)
    field = context.texture((256, 64), 1, voxels.tobytes(), dtype="u4")
    field.bind_to_image(5, read=True, write=False)
    depth0 = context.texture((8, 8), 1, np.full((8, 8), 0.5, dtype="f4").tobytes(), dtype="f4")
    depth1 = context.texture((8, 8), 1, np.full((8, 8), 0.5, dtype="f4").tobytes(), dtype="f4")
    colour = context.texture((8, 8), 4, dtype="f4")
    for unit, name, texture in [(0, "shadowtex0", depth0), (1, "shadowtex1", depth1), (2, "shadowcolor0", colour)]:
        texture.use(unit)
        shader[name].value = unit
    colour.write(np.tile(np.array([0.25, 0.75, 0.5, 1], dtype="f4"), (8, 8, 1)).tobytes())
    output = context.texture((1, 1), 4, dtype="f4")
    context.framebuffer([output]).use()
    context.viewport = (0, 0, 1, 1)
    vao = context.vertex_array(shader, [])

    def render():
        vao.render(moderngl.TRIANGLES, vertices=3)
        result = np.frombuffer(output.read(), dtype="f4").copy()
        assert np.isfinite(result).all()
        return result

    valid = render()
    assert valid[1] > valid[0] * 2, "Matching surface texture was lost"
    invalid = matrices["shadowModelViewInverse"].copy()
    invalid[1, 3] += 2
    shader["shadowModelViewInverse"].write(np.asarray(invalid.T, dtype="f4").tobytes())
    assert np.max(abs(render() - [0.4, 0.4, 0.4, 1])) < 1e-6, "Another voxel supplied reflection detail"
    shader["shadowModelViewInverse"].write(np.asarray(matrices["shadowModelViewInverse"].T, dtype="f4").tobytes())
    colour.write(np.tile(np.array([0.25, 0.75, 0.5, 0.5], dtype="f4"), (8, 8, 1)).tobytes())
    assert np.max(abs(render() - [0.4, 0.4, 0.4, 1])) < 1e-6, "Transparent carrier supplied opaque colour"
    report = {"renderer": context.info["GL_RENDERER"], "matching_surface_detail_retained": True,
        "different_voxel_rejected": True, "transparent_carrier_rejected": True,
        "scope": "Production detail guards with controlled matrices and colour conversion; no native scene claim"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
