#!/usr/bin/env python3
"""Check the production glossy BRDF independently of Minecraft scene buffers."""

import argparse
import json
from pathlib import Path

import moderngl
import numpy as np

from check_local_lighting import QUAD
from preview.shader_source import inline_shader, modernize


def main():
    """Compare the isotropic limit and a ninety-degree tangent rotation on GPU."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shader-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    context = moderngl.create_standalone_context(require=450)
    source = inline_shader(args.shader_dir / "lib/materials.glsl", args.shader_dir)
    source += """
    void main() {
        vec2 slope = (gl_FragCoord.xy / 128.0 * 2.0 - 1.0) * 1.5;
        vec3 light = normalize(vec3(slope, 1.0));
        vec3 normal = vec3(0.0, 0.0, 1.0);
        SurfaceMaterial material;
        material.f0 = vec3(0.7);
        material.roughness = 0.45;
        material.metallic = 1.0;
        float reference = materialLightSpecular(material, normal, normal, light, vec3(1.0)).r;
        float isotropic = materialAnisotropicSpecular(material, normal, vec3(1.0, 0.0, 0.0),
            normal, light, vec3(1.0), 0.0).r;
        float horizontal = materialAnisotropicSpecular(material, normal, vec3(1.0, 0.0, 0.0),
            normal, light, vec3(1.0), 0.8).r;
        float vertical = materialAnisotropicSpecular(material, normal, vec3(0.0, 1.0, 0.0),
            normal, light, vec3(1.0), 0.8).r;
        fullOut0 = vec4(reference, isotropic, horizontal, vertical);
    }
    """
    program = context.program(vertex_shader=QUAD,
        fragment_shader="#version 450 core\n" + modernize(source, "fsh"))
    texture = context.texture((128, 128), 4, dtype="f4")
    context.framebuffer([texture]).use()
    context.viewport = (0, 0, 128, 128)
    context.vertex_array(program, []).render(moderngl.TRIANGLES, vertices=3)
    result = np.frombuffer(texture.read(), dtype="f4").reshape(128, 128, 4)
    assert np.isfinite(result).all() and result.min() >= 0.0
    error = float(np.max(abs(result[..., 0] - result[..., 1])))
    rotation = float(np.max(abs(result[..., 2] - result[..., 3].T)))
    assert error < 1e-4, "Anisotropic BRDF disagrees with isotropic GGX at zero anisotropy"
    assert rotation < 1e-4, "Highlight fails to rotate with the material tangent"
    assert np.max(abs(result[..., 2] - result[..., 3])) > 0.1
    report = {
        "renderer": context.info["GL_RENDERER"],
        "isotropic_limit_max_error": error,
        "tangent_rotation_max_error": rotation,
        "finite_nonnegative": True,
        "scope": "Standalone production GLSL; native material appearance is checked separately",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
