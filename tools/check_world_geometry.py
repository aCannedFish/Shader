#!/usr/bin/env python3
"""Test real production geometry scatter independently of engine submission."""
import json
from pathlib import Path
import subprocess

import numpy as np
from preview.source import expand
from preview.migration_world import build

ROOT = Path(__file__).resolve().parents[1]


def main():
    folder = ROOT / 'local-docs/migration/runs/P03-geometry-driver'
    folder.mkdir(parents=True, exist_ok=True)
    pack = ROOT / 'local-docs/migration/prototypes/P03/shaders'
    contract = build(pack)
    vertex = folder / 'capture.vert'
    vertex.write_text('''#version 330 core
out WorldVertex {
    vec3 centre;
    vec3 position;
    vec2 uv;
    vec3 colour;
    float material;
    float light;
} vertex;
void main() {
    const vec3 points[5] = vec3[](vec3(-40,0,0),vec3(40,0,0),
        vec3(0,0,-40),vec3(0,0,40),vec3(0,0,0));
    int triangle = gl_VertexID / 3;
    int corner = gl_VertexID % 3;
    vec3 p = points[triangle];
    vec3 offset = vec3(corner == 1 ? 1.0 : 0.0, 0.0, corner == 2 ? 1.0 : 0.0);
    vertex.centre = p + vec3(.5);
    vertex.position = p + offset;
    vertex.uv = vec2(.5);
    vertex.colour = vec3(1.0);
    vertex.material = 301.0;
    vertex.light = 240.0;
    gl_Position = vec4(0,0,0,1);
}
''')
    geometry = folder / 'capture.geom'
    geometry.write_text(expand(pack / 'shadow.gsh', pack))
    fragment = folder / 'capture.frag'
    fragment.write_text('''#version 330 core
in vec2 sampleUv;
in vec3 sampleColour;
flat in int captureRoute;
flat in vec4 captureMetadata;
layout(location=0) out vec4 result;
void main() {
    result = captureRoute == 1 ? captureMetadata : vec4(0);
}
''')
    binary = folder / 'world-probe'
    subprocess.run(['clang', '-O2', '-Wno-deprecated-declarations', '-framework', 'OpenGL',
                    str(ROOT / 'tools/preview/world_probe.c'), '-o', str(binary)], check=True)
    side = contract['capture']['width']
    output = folder / 'scatter.raw'
    subprocess.run([str(binary), str(fragment), str(side), str(side), '1', 'RGBA32F', str(output),
                    str(vertex), str(geometry), '15'], check=True)
    values = np.fromfile(output, '<f4').reshape(side, side, 4)
    points = np.array([[-40,0,0],[40,0,0],[0,0,-40],[0,0,40],[0,0,0]])
    region = contract['capture']['regions']['capture_far']
    origin = -np.array(contract['far_shape']) // 2
    samples = []
    for point in points:
        x,y,z = point - origin
        px = region['x'] + x + z % 8 * contract['far_shape'][0]
        py = region['y'] + y + z // 8 * contract['far_shape'][1]
        value = values[py,px]
        samples.append({'point':point.tolist(),'value':value.tolist(),'passed':bool(value[0] == 301)})
    report = {'passed':all(row['passed'] for row in samples),'samples':samples,
              'scope':'Driver executes production geometry stage, independent of J9 chunk submission'}
    (folder / 'verification.json').write_text(json.dumps(report, indent=2)+'\n')
    assert report['passed'], report
    print('All production geometry scatter positions passed')


if __name__ == '__main__':
    main()
