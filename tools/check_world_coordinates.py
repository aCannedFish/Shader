#!/usr/bin/env python3
"""Exercise production coordinate functions and byte storage on native OpenGL."""
import json
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    folder = ROOT / 'local-docs/migration/runs/P03-coordinates'
    folder.mkdir(parents=True, exist_ok=True)
    header = (ROOT / 'shaders/lib/world/coordinates.glsl').read_text()
    source = '''#version 330 core
'''+header+'''
uniform sampler2D previous;
uniform int probeFrame;
layout(location=0) out vec4 result;
void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    int index = pixel.x + pixel.y * 128;
    uint bits = uint(index) * 2654435761u;
    if (probeFrame == 0) {
        result = worldEncodeUint(bits);
        return;
    }
    bool bytes = worldDecodeUint(texelFetch(previous, pixel, 0)) == bits;
    bytes = bytes && worldDecodeInt(worldEncodeInt(int(bits))) == int(bits);
    // Both edges of the loader's normal range, negative fractions, half cells
    // and non-cubic volumes share the exact production conversion functions.
    vec3 camera = vec3(index % 2 == 0 ? -999999.75 : 999999.25,
        -63.25 + float(index % 1024), -999999.125);
    vec3 relative = vec3(float(index % 71) - 35.125,
        float(index % 97) * 0.25 - 12.375, float(index % 43) - 21.875);
    WorldPosition position = worldPosition(relative, camera);
    bool roundtrip = length(worldCameraRelative(position, camera) - relative) < 0.00001;
    int rate = index % 2 + 1;
    ivec3 shape = ivec3(96, 80, 64);
    ivec3 origin = worldAlignedOrigin(camera, shape, rate, 4);
    ivec3 cell = worldGridCell(position, origin, rate);
    vec3 fraction = fract(position.fraction * float(rate));
    WorldPosition restored = worldCellPosition(cell, origin, rate, fraction);
    roundtrip = roundtrip && all(equal(restored.block, position.block))
        && length(restored.fraction - position.fraction) < 0.00001;
    ivec3 addressCell = ivec3(index % 96, (index / 96) % 80, (index / 7680) % 64);
    int address = worldCellIndex(addressCell, shape);
    bool addresses = all(equal(worldIndexCell(address, shape), addressCell));
    addresses = addresses && worldCellIndex(ivec3(-1, 0, 0), shape) == -1
        && worldCellIndex(shape, shape) == -1
        && all(equal(worldIndexCell(-1, shape), ivec3(-1)))
        && all(equal(worldRecordPixel(-1, 128), ivec2(-1)));
    bool lifetime = worldFrameContinuous(vec3(0), vec3(1), 0, 720719)
        && !worldFrameContinuous(vec3(0), vec3(1000), 12, 11)
        && !worldFrameContinuous(vec3(0), vec3(0), 12, 10);
    lifetime = lifetime && worldFloorDivide(-1, 4) == -1
        && worldFloorDivide(-4, 4) == -1 && worldFloorDivide(-5, 4) == -2;
    result = vec4(bytes, roundtrip, addresses, lifetime);
}
'''
    shader = folder / 'coordinates.frag'
    shader.write_text(source)
    binary = folder / 'world-probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/world_probe.c'), '-o', str(binary)], check=True)
    report = {}
    for storage in ('RGBA16F', 'RGBA32F'):
        output = folder / (storage + '.raw')
        run = subprocess.run([str(binary), str(shader), '128', '128', '2', storage, str(output)],
                             text=True, capture_output=True, check=True)
        values = np.fromfile(output, dtype=np.float32).reshape(-1, 4)
        failed = np.count_nonzero(values != 1, axis=0).tolist()
        report[storage] = {**json.loads(run.stdout), 'failures': dict(zip(
            ('byte_storage', 'position_roundtrip', 'atlas_addresses', 'frame_lifetime'), failed)),
            'passed': not any(failed)}
    (folder / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    assert all(row['passed'] for row in report.values()), report
    print('32768 native coordinate/byte cases passed in RGBA16F and RGBA32F')


if __name__ == '__main__':
    main()
