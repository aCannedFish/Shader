#!/usr/bin/env python3
"""Test first opaque reflection hits in a separate synthetic GL context.

The closed room and outside colours exist only in this test. Minecraft receives
no fixture textures, geometry, lights or other world data.
"""
import argparse
import json
from pathlib import Path

import moderngl
import numpy as np

from check_local_lighting import PREAMBLE, QUAD, production


def main():
    """A closed room must stop every axial ray before the coloured outside wall."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    context = moderngl.create_standalone_context(require=450)
    callbacks = """
    #define SIMPLE_VARYING in
    #define GI_QUALITY 1
    #define MIN_AMBIENT_LIGHT 0.0
    #define AMBIENT_STRENGTH 1.0
    const float EPSILON = 0.00001;
    uniform mat4 shadowProjection;
    uniform mat4 shadowModelView;
    uniform sampler2D shadowtex1;
    vec3 viewToAbsoluteWorld(vec3 p) { return p + cameraPosition; }
    vec3 materialAmbientEnvironment(vec3 n, vec2 lm) { return vec3(1.0); }
    vec3 distortShadow(vec3 p) { return p; }
    float filteredShadowVisibility(sampler2D s, vec2 uv, float z) { return 1.0; }
    vec3 getSunLightColor() { return vec3(0.0); }
    vec3 getSunDirWorld() { return vec3(0.0, 1.0, 0.0); }
    """
    body = """
    layout(location=0) out vec4 result;
    void main() {
        int face = int(gl_FragCoord.x);
        vec3 direction = vec3(0.0);
        direction[face / 2] = face % 2 == 0 ? 1.0 : -1.0;
        float distance;
        vec4 hit = reflectionNearestVoxel(vec3(0.0), direction, vec3(0.0), distance);
        result = vec4(hit.rgb, distance);
    }
    """
    source = PREAMBLE + callbacks + production("shaders/lib/conventional_lpv.glsl")
    source += production("shaders/lib/reflection_voxel_visibility.glsl") + body
    shader = context.program(vertex_shader=QUAD, fragment_shader=source)
    shader["cameraPosition"].value = (16.5, 8.5, 16.5)
    shader["frameCounter"].value = 1
    shader["gbufferModelViewInverse"].write(np.eye(4, dtype="f4").tobytes())
    headers = np.zeros((65, 256, 4), dtype="f4")
    headers[0, 0] = (32, 1, 0, 1961)
    first = context.texture((256, 65), 4, headers.tobytes(), dtype="f4")
    second = context.texture((256, 65), 4, headers.tobytes(), dtype="f4")
    first.use(0)
    second.use(1)
    shader["colortex8"].value = 0
    shader["colortex10"].value = 1
    voxels = np.zeros((32, 16, 32), dtype="u4")
    for z in range(12, 21):
        for y in range(4, 13):
            for x in range(12, 21):
                if x in (12, 20) or y in (4, 12) or z in (12, 20):
                    voxels[z, y, x] = (2 << 30) | (1 << 28) | (255 << 8)
    # Red exterior geometry must never replace the green interior boundary.
    voxels[:, :, 25] = (2 << 30) | (1 << 28) | 255
    field = context.texture((256, 64), 1, voxels.tobytes(), dtype="u4")
    field.bind_to_image(5, read=True, write=False)
    output = context.texture((6, 1), 4, dtype="f4")
    context.framebuffer([output]).use()
    context.viewport = (0, 0, 6, 1)
    context.vertex_array(shader, []).render(moderngl.TRIANGLES, vertices=3)
    data = np.frombuffer(output.read(), dtype="f4").reshape(6, 4)
    assert np.isfinite(data).all()
    assert np.max(np.abs(data[:, :3] - (0, 1, 0))) < 0.001, "Exterior geometry leaked through room wall"
    assert np.max(np.abs(data[:, 3] - 3.5)) < 0.001, "Incorrect first wall distance"
    # Surface origins can quantize into their own receiving block. It must not
    # replace the real reflected wall at zero distance.
    voxels[16, 8, 16] = (2 << 30) | (1 << 28) | 255 | (255 << 8) | (255 << 16)
    field.write(voxels.tobytes())
    context.vertex_array(shader, []).render(moderngl.TRIANGLES, vertices=3)
    receiver_case = np.frombuffer(output.read(), dtype="f4").reshape(6, 4)
    assert np.max(np.abs(receiver_case - data)) < 0.001, "Receiving voxel reflects itself"
    report = {"renderer": context.info["GL_RENDERER"], "six_closed_room_rays_stop_at_wall": True,
        "outside_surface_rejected": True, "receiver_self_hit_rejected": True,
        "distances": data[:, 3].tolist(),
        "scope": "Production DDA with controlled unit ambient; no Minecraft visual/performance claim"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
