#!/usr/bin/env python3
"""Check immutable face conventions and GPU decoding of every model-face record."""
import argparse
import json
from pathlib import Path
import subprocess
import shutil

import numpy as np
from preview.source import expand
from world_surfaces import CORNERS, default_uv, face_uv, SURFACE_START

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pack', type=Path, default=ROOT/'local-docs/migration/prototypes/P04-model-uv-2d/shaders')
    parser.add_argument('--output', type=Path, default=ROOT/'local-docs/migration/runs/P04-model-face-codec')
    args = parser.parse_args()
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    pack = args.pack.resolve()
    catalog = json.loads((pack/'world-definitions.json').read_text())
    faces = json.loads((pack/'world-surfaces.json').read_text())
    conventions = json.loads((ROOT/'local-docs/migration/registry/face-conventions-v1/faces.json').read_text())
    for name, face in conventions.items():
        assert np.array_equal(CORNERS[name], face['corners']), name
        for degrees in (0, 90, 180, 270):
            expected = face['uv_rotations']['R'+str(degrees)]
            assert np.allclose(face_uv(default_uv([1,2,3], [11,13,15], name), degrees), expected), name
    records = np.fromfile(pack/'textures/world-static.bin', '<f4').reshape(-1,4)
    states, start, references, count = map(int, records[SURFACE_START])
    assert count == len(faces['quads']) and start+count*4 <= references
    assert catalog['surface_contract']['end'] < len(records)-1
    flat_refs = records[references:].reshape(-1)
    for state in catalog['states']:
        first, length = records[states+state['id'], :2].astype(int)
        actual = flat_refs[first:first+length].astype(int)
        expected = sorted({quad for group in faces['state_groups'][state['id']-1]
                           for application in faces['groups'][group] for quad in faces['applications'][application]})
        assert np.array_equal(actual, expected), state['id']
    fragment = folder/'faces.fsh'
    fragment.write_text('''#version 330 core
#include "/lib/world/model_surface.glsl"
uniform sampler2D previous;
layout(location=0) out vec4 result;
void main() {
    int index = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 512;
    int faceIndex = index / 4;
    ivec4 header = worldSurfaceHeader(previous);
    result = vec4(0.0);
    if (faceIndex >= header.w) return;
    WorldModelFace face = worldModelFace(previous, faceIndex);
    if (index % 4 == 0) result = vec4(face.a, face.texture * 256 + (face.tint + 1) * 16 + int(face.shaded) * 8 + face.face);
    if (index % 4 == 1) result = vec4(face.b, face.u.z);
    if (index % 4 == 2) result = vec4(face.c, face.v.z);
    if (index % 4 == 3) result = vec4(face.u.xy, face.v.xy);
}
''')
    expanded = folder/'faces.frag'
    entry = pack/'.migration-faces-probe.fsh'
    shutil.copy2(ROOT/'shaders/lib/world/model_surface.glsl', pack/'lib/world/model_surface.glsl')
    try:
        shutil.copy2(fragment, entry)
        expanded.write_text(expand(entry, pack))
    finally:
        entry.unlink(missing_ok=True)
    binary = folder/'world-probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT/'tools/preview/world_probe.c'), '-o', str(binary)], check=True)
    output = folder/'decoded.raw'
    subprocess.run([str(binary), str(expanded), '512', '1024', '1', 'RGBA32F', str(output),
                    str(pack/'textures/world-static.bin'), 'RGBA32F'], check=True)
    decoded = np.fromfile(output, '<f4').reshape(-1,4)[:count*4]
    expected = records[start:start+count*4]
    errors = int(np.count_nonzero(decoded != expected))
    report = {'passed': errors == 0, 'faces': count, 'state_lists': len(catalog['states']),
              'reference_entries': catalog['surface_contract']['references'], 'decode_errors': errors,
              'face_winding_cases': 6, 'engine_uv_convention_cases': 24,
              'static_texels_remaining': int(len(records)-1-catalog['surface_contract']['end']),
              'scope': 'Immutable face/index data and native GL decode; actual mesh identity is a separate game test'}
    (folder/'verification.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
