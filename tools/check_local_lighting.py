#!/usr/bin/env python3
"""Exercise production local-light shaders on an offscreen OpenGL 4.5 context.

Synthetic fixtures verify atomic capture, three independent colours, wall
visibility, source removal, origin shifts and frame rollover. This does not
measure Minecraft frame rate or validate native geometry submission.
"""
import json
from pathlib import Path

import moderngl
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SIDE = 32
WIDTH = SIDE * 8
HEIGHT = SIDE * SIDE // 16 + 1
SHAPE = np.array((SIDE, SIDE // 2, SIDE))
PREAMBLE = '''#version 450 core
#define ENABLE_COLOURED_LIGHTING 1
#define COLOURED_VOLUME_SIZE 32
#define COLOURED_LIGHT_INTENSITY 1.0
#define BLOCK_LIGHT_STRENGTH 1.0
#define BLOCK_LIGHT_FALLOFF 6.0
uniform int frameCounter;
uniform int renderStage;
uniform vec3 cameraPosition;
uniform mat4 gbufferModelViewInverse;
'''
QUAD = '''#version 450 core
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
'''


def production(path):
    """Use production function bodies with a small explicit uniform interface."""
    source = (ROOT / path).read_text(encoding="utf-8-sig")
    return "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#include"))


def index(cell):
    return int(cell[0] + SHAPE[0] * (cell[1] + SHAPE[1] * cell[2]))


def main():
    context = moderngl.create_standalone_context(require=450)
    library = production("shaders/lib/conventional_lpv.glsl")
    capture_source = PREAMBLE + library + production("shaders/lib/conventional_voxel.glsl") + '''
    in vec3 fixtureCentre;
    in int fixtureMaterial;
    void main() {
        lpvCaptureVertex(fixtureCentre, fixtureMaterial);
        gl_Position = vec4(0.0);
    }
    '''
    capture = context.program(vertex_shader=capture_source)
    propagation = context.program(vertex_shader=QUAD, fragment_shader=PREAMBLE + library
        + production("shaders/program/conventional_lpv.fsh.glsl"))
    visibility_cache = context.program(vertex_shader=QUAD, fragment_shader=PREAMBLE + library
        + production("shaders/program/conventional_visibility.fsh.glsl"))
    probe = context.program(vertex_shader=QUAD, fragment_shader=PREAMBLE + library + '''
    uniform ivec3 sources[3];
    uniform vec3 receiver;
    layout(location=0) out vec4 result;
    void main() {
        int entry = int(gl_FragCoord.x);
        uint material = lpvVoxel(sources[entry]);
        vec3 colour = lpvColour(material);
        float distance = length(vec3(sources[entry]) + vec3(0.5, 0.72, 0.5) - receiver);
        result = vec4(colour * colour * lpvSourceEnergy(distance, lpvEmission(material))
            * lpvVisibility(receiver, sources[entry]), 1.0);
    }
    ''')
    validity = context.program(vertex_shader=QUAD, fragment_shader=PREAMBLE + library + '''
    layout(location=0) out vec4 result;
    void main() { result = vec4(float(lpvHeaderValid(texelFetch(colortex8, ivec2(0), 0)))); }
    ''')
    surface = context.program(vertex_shader=QUAD, fragment_shader=PREAMBLE + library + '''
    uniform vec3 receiver;
    layout(location=0) out vec4 result;
    void main() {
        vec3 view = receiver + vec3(lpvOrigin(cameraPosition)) - cameraPosition - vec3(0.0, 0.04, 0.0);
        result = vec4(lpvBlockLight(view, vec3(0.0, 1.0, 0.0), vec3(0.001, 0.0003, 0.0001)), 1.0);
    }
    ''')
    surface["gbufferModelViewInverse"].write(np.eye(4, dtype="f4").tobytes())
    occupancy = context.texture((WIDTH, HEIGHT), 1, dtype="u4")
    occupancy.bind_to_image(5, read=True, write=True)
    fields = [(context.texture((WIDTH, HEIGHT), 4, dtype="f2"),
               context.texture((WIDTH, HEIGHT), 4, dtype="f4")) for _ in range(2)]
    framebuffers = [context.framebuffer(color_attachments=pair) for pair in fields]
    transmission = context.texture((WIDTH, HEIGHT * 3), 4, dtype="f1")
    transmission_fbo = context.framebuffer([transmission])
    transmission_quad = context.vertex_array(visibility_cache, [])
    for pair in fields:
        for texture in pair:
            item_size = 2 if texture.dtype == "f2" else 4
            texture.write(bytes(WIDTH * HEIGHT * 4 * item_size))
    target = context.texture((3, 1), 4, dtype="f4")
    target_fbo = context.framebuffer(color_attachments=[target])
    quad = context.vertex_array(propagation, [])
    probe_quad = context.vertex_array(probe, [])
    valid_quad = context.vertex_array(validity, [])
    surface_quad = context.vertex_array(surface, [])
    camera = np.array((16.0, 8.0, 16.0))
    origin = np.array((0, 0, 0))
    current = 0
    frame = 0

    def bindings(program):
        fields[current][0].use(0)
        occupancy.use(1)
        fields[current][1].use(2)
        transmission.use(3)
        for name, value in (("colortex8", 0), ("shadowcolor1", 1), ("colortex10", 2), ("colortex11", 3),
                            ("cameraPosition", tuple(camera)), ("frameCounter", frame)):
            if name in program:
                program[name].value = value

    def capture_fixture(entries, stage=8):
        """Submit native-style vertices, including colliding materials, to atomic capture."""
        occupancy.write(bytes(WIDTH * HEIGHT * 4))
        data = np.zeros(len(entries), dtype=[("position", "f4", 3), ("material", "i4")])
        for row, (cell, material) in zip(data, entries):
            row["position"] = np.asarray(cell) + 0.5 + origin
            row["material"] = material
        buffer = context.buffer(data.tobytes())
        vao = context.vertex_array(capture, [(buffer, "3f 1i", "fixtureCentre", "fixtureMaterial")])
        capture["cameraPosition"].value = tuple(camera)
        capture["renderStage"].value = stage
        target_fbo.use()
        context.enable(moderngl.RASTERIZER_DISCARD)
        vao.render(mode=moderngl.POINTS)
        context.disable(moderngl.RASTERIZER_DISCARD)
        context.memory_barrier()
        vao.release()
        buffer.release()

    def update_visibility():
        """Publish each source's production RGB visibility cache."""
        bindings(visibility_cache)
        transmission_fbo.use()
        context.viewport = (0, 0, WIDTH, HEIGHT * 3)
        transmission_quad.render(vertices=3)
        context.memory_barrier()

    def propagate(count=1):
        nonlocal current, frame
        for _ in range(count):
            frame = (frame + 1) % 720720
            bindings(propagation)
            framebuffers[1 - current].use()
            context.viewport = (0, 0, WIDTH, HEIGHT)
            quad.render(vertices=3)
            context.memory_barrier()
            current = 1 - current
        update_visibility()

    def candidates_at(cell):
        values = np.frombuffer(fields[current][1].read(), np.float32).reshape(-1, 4)
        return set(int(round(value)) - 1 for value in values[index(cell) + 2, :3] if value > 0)

    def cached_visibility(cell):
        """Match each source identity to its independently resolved RGB slice."""
        identities = np.frombuffer(fields[current][1].read(), np.float32).reshape(-1, 4)
        cache = np.frombuffer(transmission.read(), np.uint8).reshape(3, HEIGHT * WIDTH, 4)
        address = index(cell) + 2
        return {int(round(identity)) - 1: cache[entry, address, :3] / 255.0
                for entry, identity in enumerate(identities[address, :3]) if identity > 0}

    def visibility_values(sources, receiver):
        bindings(probe)
        probe["sources"].write(np.asarray(sources, dtype="i4").tobytes())
        probe["receiver"].value = tuple(receiver)
        target_fbo.use()
        context.viewport = (0, 0, 3, 1)
        probe_quad.render(vertices=3)
        return np.frombuffer(target.read(), np.float32).reshape(3, 4)[:, :3].copy()

    def history_valid():
        bindings(validity)
        target_fbo.use()
        context.viewport = (0, 0, 3, 1)
        valid_quad.render(vertices=3)
        return bool(np.frombuffer(target.read(), np.float32)[0] > 0.5)

    # Every ordering must publish the same emitter even when another submitted
    # material covers the same logical cell. Floating-point imageStore races
    # previously had no ordering or material-priority guarantee.
    rng = np.random.default_rng(20261027)
    collisions = [((8, 7, 8), material) for material in (6002, 1, 110, 6001, 6005) for _ in range(200)]
    encodings = []
    for _ in range(16):
        rng.shuffle(collisions)
        capture_fixture(collisions)
        encoded = np.frombuffer(occupancy.read(), np.uint32)[index((8, 7, 8))]
        encodings.append(int(encoded))
    assert len(set(encodings)) == 1 and encodings[0] >> 30 == 3, encodings
    # J9 terrain stages are non-contiguous. Entity and hand vertices can retain
    # a lamp attribute from a prior terrain draw, but must never publish voxels.
    for stage in (10, 11, 12, 13, 14, 15, 18, 20, 22):
        capture_fixture(collisions, stage)
        assert not np.any(np.frombuffer(occupancy.read(), np.uint32)), stage
    for stage in (8, 9, 16):
        capture_fixture(collisions, stage)
        assert np.any(np.frombuffer(occupancy.read(), np.uint32)), stage

    sources = [(9, 7, 12), (15, 7, 8), (17, 7, 14)]
    materials = [6002, 6001, 6005]
    entries = list(zip(sources, materials))
    receiver = np.array((14.5, 7.72, 12.5))
    capture_fixture(entries)
    propagate(64)
    assert candidates_at((14, 7, 12)) == {index(source) for source in sources}
    open_values = visibility_values(sources, receiver)
    assert np.all(np.max(open_values, axis=1) > 0), open_values
    assert np.argmax(open_values, axis=1).tolist() == [0, 2, 1], open_values
    open_cache = cached_visibility((14, 7, 12))
    assert all(np.array_equal(value, np.ones(3)) for value in open_cache.values())
    static_before = np.frombuffer(fields[current][1].read(), np.float32).copy()
    propagate(16)
    static_after = np.frombuffer(fields[current][1].read(), np.float32)
    assert np.array_equal(static_before[8:], static_after[8:]), "Source identities drift in a static scene"

    capture_fixture(entries + [((11, 7, 12), 1)])
    propagate(1)
    blocked_values = visibility_values(sources, receiver)
    assert np.max(blocked_values[0]) == 0, blocked_values
    assert np.array_equal(blocked_values[1:], open_values[1:]), "One source's shadow changed another source"
    blocked_cache = cached_visibility((14, 7, 12))
    assert np.max(blocked_cache[index(sources[0])]) == 0.0
    for source in sources[1:]:
        assert np.array_equal(blocked_cache[index(source)], open_cache[index(source)])

    capture_fixture(entries + [((11, 7, 12), 110)])
    propagate(1)
    glass_cache = cached_visibility((14, 7, 12))[index(sources[0])]
    assert 0.0 < glass_cache[0] < glass_cache[1] < glass_cache[2] <= 1.0

    # The two faces of an opaque wall retain illumination from their own side.
    # Starting just outside a receiving face must not immediately hit that face.
    wall = [((12, y, z), 1) for y in range(16) for z in range(32)]
    capture_fixture(entries + wall)
    left_face = visibility_values(sources, np.array((11.96, 7.72, 12.5)))
    right_face = visibility_values(sources, np.array((13.04, 7.72, 12.5)))
    assert left_face[0, 0] > 0 and np.max(left_face[1:]) == 0, left_face
    assert np.max(right_face[0]) == 0 and np.all(np.max(right_face[1:], axis=1) > 0), right_face

    # Sample across an empty grid boundary. Independent source radiance must
    # change continuously instead of adopting another cell's mixed hue.
    capture_fixture(entries)
    boundary_left = visibility_values(sources, np.array((13.9999, 7.72, 12.5)))
    boundary_right = visibility_values(sources, np.array((14.0001, 7.72, 12.5)))
    assert np.max(np.abs(boundary_left - boundary_right)) < 0.00002

    # Move the camera one block and rebase the captured world. The world source
    # IDs must move with it, rather than resolving to a neighbouring block.
    camera[0] += 1
    origin[0] += 1
    shifted_sources = [tuple(np.asarray(source) - origin) for source in sources]
    capture_fixture(list(zip(shifted_sources, materials)))
    propagate(1)
    shifted = visibility_values(shifted_sources, receiver - origin)
    assert np.allclose(shifted, open_values, atol=1e-7), (shifted, open_values)
    assert candidates_at(np.array((14, 7, 12)) - origin) == {index(source) for source in shifted_sources}

    capture_fixture([(shifted_sources[0], materials[0]), (shifted_sources[2], materials[2])])
    propagate(1)
    assert index(shifted_sources[1]) not in candidates_at(np.array((14, 7, 12)) - origin)
    camera[0] += 64
    assert not history_valid(), "Teleport accepted unrelated history"
    camera[0] -= 64
    header = np.frombuffer(fields[current][0].read(), np.float16).copy()
    header[:4] = (32, 720719 % 1024, 720719 // 1024, 1961)
    fields[current][0].write(header.tobytes())
    source_header = np.frombuffer(fields[current][1].read(), np.float32).copy()
    source_header[:4] = header[:4]
    fields[current][1].write(source_header.tobytes())
    frame = 0
    assert history_valid(), "Frame rollover rejected valid history"

    camera[:] = (8208.0, 8200.0, 8208.0)
    origin[:] = (8192, 8192, 8192)
    capture_fixture(entries)
    propagate(2)
    assert history_valid(), "Full-float world origin was rounded"
    assert np.isfinite(np.frombuffer(fields[current][0].read(), np.float16)).all()

    # Deliberately change the third candidate at a block boundary while keeping
    # the first two fixed. The complete surface-light function must blend the
    # outgoing and incoming colours across the boundary.
    camera[:] = (16.0, 8.0, 16.0)
    origin[:] = (0, 0, 0)
    fourth = (17, 7, 10)
    capture_fixture(entries + [(fourth, 6006)])
    propagate(2)
    source_data = np.frombuffer(fields[current][1].read(), np.float32).copy().reshape(-1, 4)
    for cell_index in range(int(np.prod(SHAPE))):
        cell_x = cell_index % 32
        source_data[cell_index + 2, :3] = [index(sources[0]) + 1, index(sources[1]) + 1,
            index(sources[2] if cell_x < 14 else fourth) + 1]
    fields[current][1].write(source_data.tobytes())
    update_visibility()
    boundary_colours = []
    for x in (13.9999, 14.0001):
        bindings(surface)
        surface["receiver"].value = (x, 7.72, 12.5)
        target_fbo.use()
        context.viewport = (0, 0, 3, 1)
        surface_quad.render(vertices=3)
        boundary_colours.append(np.frombuffer(target.read(), np.float32)[:3].copy())
    assert np.max(np.abs(boundary_colours[0] - boundary_colours[1])) < 0.00002, boundary_colours

    # A world-fixed receiver near the volume edge crosses two camera origins.
    # Coverage must remain continuous while the integer storage grid advances.
    camera[:] = (16.0, 8.0, 16.0)
    origin[:] = (0, 0, 0)
    capture_fixture(entries)
    propagate(64)
    edge_colours = []
    edge_receiver = np.array((2.75, 7.72, 12.5))
    for camera_x in (16.9999, 17.0001):
        camera[0] = camera_x
        origin[0] = int(np.floor(camera_x)) - 16
        shifted_entries = [(tuple(np.asarray(cell) - origin), material)
                           for cell, material in zip(sources, materials)]
        capture_fixture(shifted_entries)
        propagate(1)
        bindings(surface)
        surface["receiver"].value = tuple(edge_receiver - origin)
        target_fbo.use()
        context.viewport = (0, 0, 3, 1)
        surface_quad.render(vertices=3)
        edge_colours.append(np.frombuffer(target.read(), np.float32)[:3].copy())
    edge_delta = float(np.max(np.abs(edge_colours[1] - edge_colours[0])))
    assert edge_delta < 0.0001, (edge_colours, edge_delta)

    report = {"renderer": context.info["GL_RENDERER"], "atomic_orderings": len(encodings),
              "continuous_camera_coverage_delta": edge_delta,
              "nonterrain_stages_rejected": [10, 11, 12, 13, 14, 15, 18, 20, 22],
              "three_sources": open_values.tolist(), "one_occluded_source": blocked_values.tolist(),
              "static_identity_drift": False, "origin_rebase": True, "source_removal": True,
              "teleport_rejected": True, "frame_rollover": True,
              "wall_receivers": True, "continuous_grid_boundary": True,
              "full_float_origin": True,
              "third_candidate_crossfade": True,
              "cached_independent_shadows": True, "cached_rgb_transmission": True,
              "scope": "Production GLSL offscreen fixtures; no native geometry or frame-rate claim."}
    output = ROOT / ".check/local-lighting/verification.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
