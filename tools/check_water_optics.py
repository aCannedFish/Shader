#!/usr/bin/env python3
"""Exercise assembled water optics in an independent OpenGL context.

Fixtures check Snell projection, foreground rejection, critical-angle Fresnel,
medium history and rain rings. No fixture data is sent to Minecraft.
"""
import argparse
import json
from pathlib import Path

import moderngl
import numpy as np

from check_local_lighting import QUAD
from preview.shader_source import inline_shader, modernize


def main():
    """Run production helper functions against controlled optical inputs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shader-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.shader_dir.resolve()
    context = moderngl.create_standalone_context(require=450)
    report = {"renderer": context.info["GL_RENDERER"], "checks": {}}

    def program(library, body, declarations=""):
        """Compile the same assembled libraries consumed by native entry points."""
        source = inline_shader(root / library, root)
        source += "\n" + declarations + "\nvoid main() {\n" + body + "\n}\n"
        return context.program(vertex_shader=QUAD,
            fragment_shader="#version 450 core\n" + modernize(source, "fsh"))

    def render(shader, size):
        """Read a floating-point framebuffer and reject invalid values."""
        texture = context.texture(size, 4, dtype="f4")
        framebuffer = context.framebuffer([texture])
        framebuffer.use()
        context.viewport = (0, 0, *size)
        context.vertex_array(shader, []).render(moderngl.TRIANGLES, vertices=3)
        result = np.frombuffer(texture.read(), dtype="f4").reshape(size[1], size[0], 4).copy()
        framebuffer.release()
        texture.release()
        assert np.isfinite(result).all(), "Invalid water output"
        return result

    fresnel = program("lib/water.glsl", """
        float angle = gl_FragCoord.x / 2048.0 * 1.57079632679;
        float cosine = cos(angle);
        fullOut0 = vec4(waterDielectricFresnel(cosine, WATER_IOR),
            waterDielectricFresnel(cosine, 1.0 / WATER_IOR),
            1.0 - WATER_IOR * WATER_IOR * (1.0 - cosine * cosine), 1.0);
    """)
    curve = render(fresnel, (2048, 1))[0]
    angle = (np.arange(2048) + 0.5) / 2048 * np.pi / 2
    critical = np.arcsin(1 / 1.333)
    assert np.all(curve[angle > critical, 0] == 1), "Total internal reflection leaks"
    assert np.all(np.diff(curve[:, 0]) >= -1e-6), "Fresnel is not monotone"
    assert abs(float(curve[0, 0]) - 0.02037) < 0.0001
    report["checks"]["critical_angle_degrees"] = float(np.degrees(critical))

    size = (256, 256)
    f = 1 / np.tan(np.radians(70) / 2)
    near, far = 0.05, 128
    projection = np.array([[f, 0, 0, 0], [0, f, 0, 0],
        [0, 0, -(far + near) / (far - near), -2 * far * near / (far - near)],
        [0, 0, -1, 0]], dtype="f4")
    cosine = np.sqrt(0.5)
    modelview = np.eye(4, dtype="f4")
    modelview[1:3, 1:3] = [[cosine, -cosine], [cosine, cosine]]
    inverse = np.linalg.inv(modelview)
    y, x = np.mgrid[:size[1], :size[0]]
    uv = np.stack(((x + 0.5) / size[0], (y + 0.5) / size[1]), axis=-1)
    rays = np.dstack(((uv[..., 0] * 2 - 1) / f,
        (uv[..., 1] * 2 - 1) / f, -np.ones_like(x)))
    world_rays = rays @ inverse[:3, :3].T

    def plane_depth(height):
        """Build the perspective depth of a horizontal plane for this camera."""
        distance = (height - 4) / world_rays[..., 1]
        position = rays * distance[..., None]
        clip_z = position[..., 2] * projection[2, 2] + projection[2, 3]
        return ((clip_z / -position[..., 2]) * 0.5 + 0.5).astype("f4")

    refraction = program("lib/water_refraction.glsl", """
        vec2 uv = gl_FragCoord.xy / vec2(256.0);
        vec3 ray = normalize(screenToView(uv, 0.5));
        vec3 worldRay = mat3(gbufferModelViewInverse) * ray;
        vec3 position = ray * (4.0 / -worldRay.y);
        vec3 bed = cameraPosition + worldRay * ((4.0 + fixtureBedDepth) / -worldRay.y);
        vec3 normal = mat3(gbufferModelView) * normalize(vec3(fixtureSlope.x, 1.0, fixtureSlope.y));
        vec2 actual = waterRefractionUv(uv, position, normal, bed,
            vec3(0.0, 1.0, 0.0), colortex13, fixtureSurface, fixtureParameters);
        vec3 bent = refract(ray, normal, 1.0 / WATER_IOR);
        float distance = fixtureBedDepth / -(mat3(gbufferModelViewInverse) * bent).y;
        vec4 clip = gbufferProjection * vec4(position + bent * distance, 1.0);
        fullOut0 = vec4(actual, clip.xy / clip.w * 0.5 + 0.5);
    """, "uniform sampler2D fixtureSurface; uniform sampler2D fixtureParameters;\n"
        "uniform float fixtureBedDepth; uniform vec2 fixtureSlope;")
    for name, matrix in {"gbufferProjection": projection,
        "gbufferProjectionInverse": np.linalg.inv(projection), "gbufferModelView": modelview,
        "gbufferModelViewInverse": inverse}.items():
        refraction[name].write(np.asarray(matrix.T, dtype="f4").tobytes())
    refraction["cameraPosition"].value = (0, 4, 0)
    refraction["viewWidth"].value = 256
    refraction["viewHeight"].value = 256
    refraction["colortex13"].value = 0
    refraction["colortex14"].value = 3
    refraction["fixtureBedDepth"].value = 4
    refraction["fixtureSlope"].value = (0, 0)
    bed_texture = context.texture(size, 1, plane_depth(-4).tobytes(), dtype="f4")
    bed_texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
    surface_field = np.zeros((256, 256, 4), dtype="f4")
    surface_field[..., :2] = 0.5
    surface_field[..., 2] = -4 / world_rays[..., 1]
    surface_field[..., 3] = 1
    surface_texture = context.texture(size, 4, surface_field.tobytes(), dtype="f4")
    surface_texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
    surface_texture.use(2)
    boundary_field = np.zeros((256, 256, 4), dtype="f4")
    boundary_texture = context.texture(size, 4, boundary_field.tobytes(), dtype="f4")
    boundary_texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
    boundary_texture.use(3)
    refraction["fixtureSurface"].value = 2
    if "fixtureParameters" in refraction:
        refraction["fixtureParameters"].value = 2
    bed_texture.use(0)
    result = render(refraction, size)
    inner = result[80:176, 80:176]
    error = np.max(np.abs(inner[..., :2] - inner[..., 2:]))
    assert error < 0.001, "Snell projection differs from the planar solution"
    shift = np.linalg.norm(inner[..., :2] - uv[80:176, 80:176], axis=-1)
    assert shift.mean() > 0.015, "No apparent-depth refraction"
    snell_error = float(error)
    for depth, slope in [(1, (0, 0)), (2, (0.06, -0.04)),
        (4, (-0.06, 0.04)), (8, (0.03, 0.02))]:
        bed_texture.write(plane_depth(-depth).tobytes())
        refraction["fixtureBedDepth"].value = depth
        refraction["fixtureSlope"].value = slope
        solved = render(refraction, size)[80:176, 80:176]
        snell_error = max(snell_error, float(np.max(abs(solved[..., :2] - solved[..., 2:]))))
    assert snell_error < 0.001, "Wave tilt and apparent depth do not follow the same Snell ray"
    refraction["fixtureBedDepth"].value = 4
    refraction["fixtureSlope"].value = (0, 0)
    bed_texture.write(plane_depth(2).tobytes())
    rejected = render(refraction, size)
    assert np.max(np.abs(rejected[..., :2] - uv)) < 1e-6, "Foreground enters refraction"
    report["checks"]["snell_projection_error_uv"] = float(error)
    report["checks"]["single_snell_depth_and_tilt_max_error_uv"] = snell_error
    report["checks"]["mean_refraction_shift_pixels"] = float(shift.mean() * 256)
    report["checks"]["foreground_rejected"] = True

    # A foreground red plane beside a green submerged bed exposes colour bleeding.
    boundary_depth = plane_depth(-4)
    boundary_depth[:, 128:] = plane_depth(2)[:, 128:]
    bed_texture.write(boundary_depth.tobytes())
    bed_texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
    colours = np.zeros((256, 256, 4), dtype="f4")
    colours[:, :128, 1] = 1
    colours[:, 128:, 0] = 1
    colours[..., 3] = 1
    colour_texture = context.texture(size, 4, colours.tobytes(), dtype="f4")
    colour_texture.use(1)
    transmission = program("lib/water_refraction.glsl", """
        vec2 uv = (gl_FragCoord.xy + vec2(0.35, 0.0)) / vec2(256.0);
        vec3 ray = mat3(gbufferModelViewInverse) * screenToView(uv, 0.5);
        vec3 bed = cameraPosition + ray * (8.0 / -ray.y);
        vec3 colour = waterTransmissionColor(fixtureColour, fixtureDepth, uv,
            bed, vec3(0.0, 1.0, 0.0), 0.0);
        fullOut0 = vec4(colour, 1.0);
    """, "uniform sampler2D fixtureColour; uniform sampler2D fixtureDepth;")
    transmission["fixtureDepth"].value = 0
    transmission["fixtureColour"].value = 1
    transmission["gbufferProjectionInverse"].write(np.asarray(np.linalg.inv(projection).T, dtype="f4").tobytes())
    transmission["gbufferModelViewInverse"].write(np.asarray(inverse.T, dtype="f4").tobytes())
    transmission["cameraPosition"].value = (0, 4, 0)
    transmission["viewWidth"].value = 256
    transmission["viewHeight"].value = 256
    filtered = render(transmission, size)[80:176, :128]
    assert filtered[..., 0].max() < 1e-6, "Shore foreground colour enters the submerged bed"
    assert filtered[..., 1].min() > 0.999, "Valid bed coverage becomes a dark seam"
    report["checks"]["shore_colour_bleed_rejected"] = True
    report["checks"]["shore_filter_preserves_bed_coverage"] = True

    # A dry edge must compress the coordinate field without folding it or piling
    # rejected samples onto one shoreline texel. This checks both offset signs.
    boundary = program("lib/water_refraction.glsl", """
        vec2 uv = gl_FragCoord.xy / vec2(256.0);
        vec2 offset = vec2(fixtureOffset, 0.0);
        float weight = waterRefractionBoundary(uv, offset, colortex14);
        fullOut0 = vec4(uv + offset * weight, weight, 1.0);
    """, "uniform float fixtureOffset;")
    boundary["viewWidth"].value = 256
    boundary["viewHeight"].value = 256
    boundary["colortex14"].value = 3
    field_y, field_x = np.mgrid[:128, :128]
    boundary_field[:128, :128, 0] = np.where(field_x < 32, 0.5, 63.5)
    boundary_field[:128, :128, 1] = field_y + 0.5
    boundary_field[:128, :128, 3] = 1
    boundary_texture.write(boundary_field.tobytes())
    boundary_texture.use(3)
    minimum_step = 1.0
    for offset in [-0.12, -0.06, 0.06, 0.12]:
        boundary["fixtureOffset"].value = offset
        mapped = render(boundary, size)[128, 16:128]
        minimum_step = min(minimum_step, float(np.diff(mapped[:, 0]).min() * 256))
        assert np.all(mapped[:, 0] < 0.5), "Refraction crosses the dry shoreline"
        assert abs(mapped[-1, 0] * 256 - 127.5) < 0.1, "Shoreline coordinate detaches from geometry"
    assert minimum_step > 0, "Shoreline coordinate field folds into a duplicate image"
    report["checks"]["shore_mapping_minimum_step_pixels"] = minimum_step
    report["checks"]["shore_mapping_stays_inside_water"] = True

    # Exercise the actual boundary producers with one-pixel water/depth breaks.
    # Their distance field must find thin faces that sparse per-ray probes miss.
    def boundary_stage(name, jump=None):
        source = inline_shader(root / "program" / name, root)
        define = "" if jump is None else f"#define WATER_BOUNDARY_JUMP {jump}\n"
        return context.program(vertex_shader=QUAD,
            fragment_shader="#version 450 core\n" + define + modernize(source, "fsh"))

    surface_field[..., 3] = 1
    surface_field[80:176, 64, 3] = 0
    surface_texture.write(surface_field.tobytes())
    surface_texture.use(2)
    thin_depth = plane_depth(-4)
    thin_depth[80:176, 128] = plane_depth(-2)[80:176, 128]
    bed_texture.write(thin_depth.tobytes())
    bed_texture.use(0)
    seed_stage = boundary_stage("water_boundary_seed.fsh.glsl")
    for name, value in {"viewWidth": 256, "viewHeight": 256,
        "colortex9": 2, "depthtex1": 0}.items():
        seed_stage[name].value = value
    seeds = render(seed_stage, size)
    assert seeds[64, 31:33, 3].max() == 1, "One-pixel dry gap was lost"
    assert seeds[64, 63:65, 3].max() == 1, "One-pixel submerged depth face was lost"
    propagated = seeds
    field = context.texture(size, 4, dtype="f2")
    field.filter = (moderngl.NEAREST, moderngl.NEAREST)
    for jump in [128, 64, 32, 16, 8, 4, 2, 1]:
        field.write(propagated.astype("f2").tobytes())
        field.use(3)
        stage = boundary_stage("water_boundary_jump.fsh.glsl", jump)
        stage["viewWidth"].value = 256
        stage["viewHeight"].value = 256
        stage["colortex14"].value = 3
        propagated = render(stage, size)
    points = np.stack((field_x + 0.5, field_y + 0.5), axis=-1)
    exact = np.full((128, 128), np.inf)
    for seed in seeds[seeds[..., 3] > 0.5, :2]:
        exact = np.minimum(exact, np.sum((points - seed) ** 2, axis=-1))
    actual = np.sum((points - propagated[:128, :128, :2]) ** 2, axis=-1)
    error = float(np.max(np.sqrt(actual) - np.sqrt(exact)) * 2)
    assert propagated[:128, :128, 3].min() == 1, "Boundary propagation leaves a hole"
    assert error < 2, "Boundary distance exceeds the conservative three-pixel margin"
    report["checks"]["native_depth_one_pixel_boundaries_preserved"] = True
    report["checks"]["boundary_distance_max_overestimate_pixels"] = error

    # Cutout identity is a flag, not opacity: changing it must not darken radiance.
    reflection_colour = program("lib/reflection_occlusion.glsl", """
        vec3 point = screenToView(vec2(0.5), 0.75);
        fullOut0 = vec4(reflectionOccluderRadiance(fixtureScene, fixtureDepth,
            point, false, vec3(0.1)), 1.0);
    """, "uniform sampler2D fixtureScene; uniform sampler2D fixtureDepth;")
    reflection_colour["fixtureScene"].value = 0
    reflection_colour["fixtureDepth"].value = 1
    for name in ["gbufferProjection", "gbufferProjectionInverse"]:
        reflection_colour[name].write(np.eye(4, dtype="f4").tobytes())
    colour = context.texture((1, 1), 4, dtype="f4")
    colour.use(0)
    depth = context.texture((1, 1), 1, np.array([0.75], dtype="f4").tobytes(), dtype="f4")
    depth.use(1)
    measured = []
    for flags in [1.0, 3.0]:
        colour.write(np.array([0.3, 0.6, 0.9, flags], dtype="f4").tobytes())
        measured.append(render(reflection_colour, (1, 1))[0, 0, :3])
    assert np.max(abs(measured[0] - measured[1])) < 1e-6, "Cutout identity darkens reflected colour"
    assert np.max(abs(measured[0] - (0.3, 0.6, 0.9))) < 1e-6
    report["checks"]["cutout_flag_preserves_reflection_radiance"] = True

    hidden_colour = program("lib/reflection_occlusion.glsl", """
        vec3 point = screenToView(vec2(0.5), 0.75);
        fullOut0 = vec4(reflectionOccluderRadiance(fixtureScene, fixtureDepth,
            point, true, vec3(0.1)), 1.0);
    """, "uniform sampler2D fixtureScene; uniform sampler2D fixtureDepth;")
    for name in ["gbufferProjection", "gbufferProjectionInverse", "gbufferModelViewInverse",
        "shadowProjection", "shadowModelView"]:
        if name in hidden_colour:
            hidden_colour[name].write(np.eye(4, dtype="f4").tobytes())
    for name, value in {"fixtureScene": 0, "fixtureDepth": 1,
        "shadowtex0": 1, "shadowtex1": 1, "shadowcolor0": 2}.items():
        if name in hidden_colour:
            hidden_colour[name].value = value
    shadow_albedo = context.texture((1, 1), 4,
        np.array([0.5, 0.4, 0.3, 0.25], dtype="f4").tobytes(), dtype="f4")
    shadow_albedo.use(2)
    expected = np.power([0.5, 0.4, 0.3], 2.2) / 3.0
    for proxy in [(0.3, 0.6, 0.9), (2, 2, 2)]:
        colour.write(np.array([*proxy, 3], dtype="f4").tobytes())
        actual = render(hidden_colour, (1, 1))[0, 0, :3]
        assert np.max(abs(actual - expected)) < 1e-5, "Hidden material receives a second screen-colour shadow"
    report["checks"]["hidden_material_uses_local_irradiance"] = True

    priority = program("lib/reflection_occlusion.glsl", """
        int mode = int(gl_FragCoord.x);
        float confidence = mode == 1 ? 0.5 : 1.0;
        float hitDistance = mode == 2 ? 20.0 : 2.0;
        float screenDistance = mode == 3 ? 0.0 : 10.0;
        bool closer = reflectionOcclusionCloser(vec4(0.1, 0.1, 0.1, confidence),
            hitDistance, screenDistance);
        fullOut0 = vec4(closer ? 1.0 : 0.0);
    """)
    classification = render(priority, (4, 1))[0, :, 0]
    assert np.array_equal(classification, [1, 0, 0, 1]), "Uncertain shadow replaces a supported screen hit"
    report["checks"]["uncertain_shadow_keeps_screen_hit"] = True

    recovery = program("lib/water_reflection.glsl", """
        float distance;
        vec4 hit = recoverWaterScene(vec3(0.0, -2.0, -4.0),
            normalize(vec3(0.0, 0.3, -1.0)), 0.02, distance);
        fullOut0 = vec4(hit.rgb * hit.a, distance);
    """)
    for name, matrix in {"gbufferProjection": projection,
        "gbufferProjectionInverse": np.linalg.inv(projection),
        "gbufferModelView": np.eye(4), "gbufferModelViewInverse": np.eye(4)}.items():
        if name in recovery:
            recovery[name].write(np.asarray(matrix.T, dtype="f4").tobytes())
    for name, value in {"near": near, "far": far, "viewWidth": 128,
        "viewHeight": 128, "cameraPosition": (0, 2, 0), "colortex6": 0, "depthtex1": 1}.items():
        if name in recovery:
            recovery[name].value = value
    wall_colour = np.tile(np.array([0.25, 0.5, 0.8, 1.0], dtype="f4"), (128, 128, 1))
    wall_depth = (projection[2, 2] * -12 + projection[2, 3]) / 12 * 0.5 + 0.5
    colours = context.texture((128, 128), 4, wall_colour.tobytes(), dtype="f4")
    depths = context.texture((128, 128), 1,
        np.full((128, 128), wall_depth, dtype="f4").tobytes(), dtype="f4")
    depths.filter = (moderngl.NEAREST, moderngl.NEAREST)
    colours.use(0)
    depths.use(1)
    recovered = render(recovery, (1, 1))[0, 0]
    assert np.max(abs(recovered[:3] - (0.25, 0.5, 0.8))) < 1e-5, "DDA recovery loses visible surface colour"
    assert abs(recovered[3] - 8 * np.sqrt(1.09)) < 0.01, "DDA recovery misses the known plane"
    report["checks"]["dda_recovery_preserves_visible_plane"] = True

    phase = program("lib/water_effects.glsl", """
        float cosine = gl_FragCoord.x / 4096.0 * 2.0 - 1.0;
        fullOut0 = vec4(waterScatteringPhase(cosine), 0.0, 0.0, 1.0);
    """)
    phase_curve = render(phase, (4096, 1))[0, :, 0]
    phase_energy = float(phase_curve.mean() * 4 * np.pi)
    assert np.all(phase_curve > 0), "Scattering phase has negative energy"
    assert np.all(np.diff(phase_curve) >= 0), "Forward scattering is not monotone"
    assert abs(phase_energy - 1) < 0.001, "Scattering phase is not energy normalized"
    report["checks"]["phase_integrated_energy"] = phase_energy
    report["checks"]["forward_to_backward_phase_ratio"] = float(phase_curve[-1] / phase_curve[0])

    segment = program("lib/water_effects.glsl", """
        int count = int(gl_FragCoord.x) + 1;
        vec3 sum = vec3(0.0);
        for (int index = 0; index < 64; index++) {
            if (index >= count) break;
            float first = float(index) / float(count);
            float second = float(index + 1) / float(count);
            sum += waterScatteringSegment(vec3(0.08, 0.15, 0.30),
                mix(fixtureOptical.x, fixtureOptical.y, first),
                mix(fixtureOptical.x, fixtureOptical.y, second), 12.0 / float(count));
        }
        fullOut0 = vec4(sum, 1.0);
    """, "uniform vec2 fixtureOptical;")
    partition_error = 0.0
    extinction = np.array([0.08, 0.15, 0.30])
    for start, end in [(2, 20), (20, 2), (12, 12), (300, 2), (2, 300)]:
        segment["fixtureOptical"].value = (start, end)
        curve = render(segment, (64, 1))[0, :, :3]
        slope = extinction * (end - start)
        factor = np.ones(3) if start == end else -np.expm1(-slope) / slope
        expected = np.exp(-extinction * start) * factor * 12
        partition_error = max(partition_error, float(np.max(abs(curve - expected))))
    assert partition_error < 1e-4, "Scattering energy changes with integration step count"
    report["checks"]["segment_partition_max_error"] = partition_error

    shafts = program("lib/water_effects.glsl", """
        vec2 uv = gl_FragCoord.xy / vec2(32.0);
        fullOut0 = vec4(integrateWaterShafts(uv, fixturePath, 3.0, 1.0), 1.0);
    """, "uniform float fixturePath;")
    for name in ["gbufferModelViewInverse", "shadowModelView"]:
        shafts[name].write(np.eye(4, dtype="f4").tobytes())
    shafts["gbufferProjectionInverse"].write(np.asarray(np.linalg.inv(projection).T, dtype="f4").tobytes())
    shadow_projection = np.diag([0.01, 0.01, 0.01, 1]).astype("f4")
    shafts["shadowProjection"].write(shadow_projection.tobytes())
    shafts["sunPosition"].value = (0, 0.8, -0.6)
    shafts["cameraPosition"].value = (0, 0, 0)
    shafts["rainStrength"].value = 0
    shafts["fixturePath"].value = 12
    shafts["shadowtex1"].value = 0
    shadow = context.texture((4, 4), 1, np.ones((4, 4), dtype="f4").tobytes(), dtype="f4")
    shadow.use(0)
    illuminated = render(shafts, (32, 32))[..., :3]
    assert illuminated.max() > 0.001, "Daylight scattering is absent"
    assert illuminated.max() < 3, "Daylight scattering is unbounded"
    shadow.write(np.zeros((4, 4), dtype="f4").tobytes())
    assert render(shafts, (32, 32))[..., :3].max() == 0, "Opaque shadow leaks scattering"
    shadow.write(np.ones((4, 4), dtype="f4").tobytes())
    shafts["sunPosition"].value = (0, -1, 0)
    assert render(shafts, (32, 32))[..., :3].max() == 0, "Night retains solar shafts"
    shafts["sunPosition"].value = (0, 0.8, -0.6)
    shafts["fixturePath"].value = 0
    assert render(shafts, (32, 32))[..., :3].max() == 0, "Zero path scatters light"
    report["checks"]["solar_scattering_peak"] = float(illuminated.max())
    report["checks"]["opaque_shadow_night_zero_path_dark"] = True

    medium = program("lib/water.glsl", """
        fullOut0 = vec4(estimateWaterMedium(fixtureSurfaces, fixtureSurfaces), 0.0, 1.0);
    """, "uniform sampler2D fixtureSurfaces;")
    # An empty geometry sample has alpha zero, so only the history is used.
    # The second texture's RGB stores the previous state for the dedicated sampler.
    empty = context.texture((1, 1), 4, np.zeros(4, dtype="f4").tobytes(), dtype="f4")
    empty.use(0)
    history = context.texture((1, 1), 4, dtype="f4")
    medium["colortex13"].value = 1
    medium["fixtureSurfaces"].value = 0
    medium["gbufferModelViewInverse"].write(np.eye(4, dtype="f4").tobytes())
    medium["gbufferProjectionInverse"].write(np.eye(4, dtype="f4").tobytes())
    medium["cameraPosition"].value = (0, 0, 0)
    medium["previousCameraPosition"].value = (0, 0, 0)
    medium["eyeBrightnessSmooth"].value = (0, 0)
    medium["frameTime"].value = 1 / 60
    values = []
    state = (6, 1, 9, 4183)
    for frame in range(10, 70):
        history.write(np.array(state, dtype="f4").tobytes())
        history.use(1)
        medium["frameCounter"].value = frame
        sample = render(medium, (1, 1))[0, 0]
        values.append(float(sample[1]))
        state = (sample[0], sample[1], frame, 4183)
    assert max(abs(np.diff(values))) < 0.06, "Medium light jumps"
    assert abs(values[-1] - np.exp(-3.5)) < 0.002
    assert abs(float(state[0]) - 6) < 0.001, "View loss changed water depth"
    report["checks"]["medium_sky_max_frame_change"] = float(max(abs(np.diff(values))))
    report["checks"]["history_depth_preserved"] = True

    ripples = program("lib/rain_ripples.glsl", """
        vec2 slope = rainRippleSlope(gl_FragCoord.xy * 0.025, frameTimeCounter, near);
        fullOut0 = vec4(slope, length(slope), 1.0);
    """)
    ripples["rainStrength"].value = 1
    ripples["rainBiome"].value = 1
    ripples["frameTimeCounter"].value = 18.4
    ripples["near"].value = 0.003
    rings = render(ripples, (256, 256))
    assert rings[..., 2].max() > 0.015, "No rain impacts"
    assert rings[..., 2].max() < 0.3, "Unbounded impact slope"
    ripples["near"].value = 1
    assert render(ripples, (32, 32))[..., 2].max() == 0, "Distant rings alias"
    ripples["near"].value = 0.003
    ripples["rainStrength"].value = 0
    assert render(ripples, (32, 32))[..., 2].max() == 0, "Dry weather has impacts"
    report["checks"]["rain_ring_peak_slope"] = float(rings[..., 2].max())
    report["checks"]["dry_and_unresolved_rings_zero"] = True

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
