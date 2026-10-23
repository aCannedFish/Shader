#!/usr/bin/env python3
"""Compare production GLSL box-union hits with independent triangle intersections.

Static shapes come from the installed vanilla block models. The CPU oracle
intersects triangle faces and rejects internal union surfaces; GLSL uses slab
intervals, so intersection, parallel-axis and self-occlusion mistakes are visible.
"""
import json
from pathlib import Path
import subprocess

import numpy as np
from world_assets import Assets, shape_fixture

ROOT = Path(__file__).resolve().parents[1]


def triangles(boxes):
    result = []
    normals = []
    for low, high in boxes:
        low, high = np.array(low), np.array(high)
        for axis in range(3):
            other = [value for value in range(3) if value != axis]
            for side in (0, 1):
                corners = []
                for a,b in ((0,0),(1,0),(1,1),(0,1)):
                    point = low.copy()
                    point[axis] = high[axis] if side else low[axis]
                    point[other[0]] = high[other[0]] if a else low[other[0]]
                    point[other[1]] = high[other[1]] if b else low[other[1]]
                    corners.append(point)
                normal = np.zeros(3)
                normal[axis] = 1 if side else -1
                for indices in ((0,1,2),(0,2,3)):
                    result.append([corners[index] for index in indices])
                    normals.append(normal)
    return np.array(result), np.array(normals)


def reference(boxes, origin, direction):
    faces, normals = triangles(boxes)
    edge1, edge2 = faces[:,1] - faces[:,0], faces[:,2] - faces[:,0]
    p = np.cross(direction[:,None], edge2)
    determinant = np.sum(edge1 * p, axis=-1)
    inverse = np.divide(1, determinant, out=np.zeros_like(determinant), where=np.abs(determinant)>1e-10)
    t = origin[:,None] - faces[:,0]
    u = np.sum(t * p, axis=-1) * inverse
    q = np.cross(t, edge1)
    v = np.sum(direction[:,None] * q, axis=-1) * inverse
    distance = np.sum(edge2 * q, axis=-1) * inverse
    valid = (np.abs(determinant)>1e-10) & (u>=-1e-8) & (v>=-1e-8) & (u+v<=1+1e-8) & (distance>=1e-5)
    point = origin[:,None] + direction[:,None] * distance[...,None]
    before = point - direction[:,None] * 2e-5
    after = point + direction[:,None] * 2e-5
    inside_before = np.zeros(valid.shape, bool)
    inside_after = np.zeros(valid.shape, bool)
    for low,high in boxes:
        inside_before |= np.all((before>low)&(before<high),axis=-1)
        inside_after |= np.all((after>low)&(after<high),axis=-1)
    valid &= inside_before != inside_after
    candidate = np.where(valid, distance, np.inf)
    index = candidate.argmin(axis=1)
    nearest = candidate[np.arange(len(origin)), index]
    hit = np.isfinite(nearest)
    output = np.zeros((len(origin),4),np.float32)
    output[:,0] = np.where(hit,nearest,-1)
    output[:,1:] = np.where(hit[:,None], normals[index], 0)
    return output


def rays(indices, states):
    sample = indices // states
    axis = sample % 3
    sign = np.where((sample // 3) % 2 == 0, 1, -1)
    u = ((sample % 127).astype(np.float32) + np.float32(.37)) / np.float32(127)
    v = (((sample // 127) % 127).astype(np.float32) + np.float32(.19)) / np.float32(127)
    origin = np.empty((len(indices),3),np.float32)
    origin[np.arange(len(indices)), axis] = np.where(sign>0,-2,3)
    origin[np.arange(len(indices)), (axis+1)%3] = u * np.float32(1.6) - np.float32(.3)
    origin[np.arange(len(indices)), (axis+2)%3] = v * np.float32(1.6) - np.float32(.3)
    inside = sample % 7 == 0
    origin[inside] = np.array([.13,.37,.71],np.float32) + u[inside,None] * np.float32(.17)
    direction = np.zeros_like(origin)
    direction[np.arange(len(indices)),axis] = sign
    return origin,direction


def main():
    folder = ROOT / 'local-docs/migration/runs/P03-shapes'
    folder.mkdir(parents=True,exist_ok=True)
    states = shape_fixture(Assets())
    assert max(len(state['boxes']) for state in states)<=32
    boxes = []
    ranges = []
    for state in states:
        ranges.append((len(boxes)*2,len(state['boxes'])))
        boxes.extend(state['boxes'])
    bounds = [point for box in boxes for point in box]
    constants = 'const ivec2 shapeRanges[] = ivec2[]('+','.join(
        f'ivec2({first},{count})' for first,count in ranges)+');\n'
    constants += 'const vec3 shapeBounds[] = vec3[]('+','.join(
        'vec3('+','.join(f'{value:.8f}' for value in point)+')' for point in bounds)+');\n'
    fragment = folder / 'shapes.frag'
    fragment.write_text('#version 330 core\n'+(ROOT/'shaders/lib/world/shapes.glsl').read_text()+'\n'+constants+f'''
uniform sampler2D previous;
uniform int probeFrame;
layout(location=0) out vec4 result;
void main() {{
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    int index = pixel.x + pixel.y * 1024;
    if (probeFrame == 0) {{
        result = index < {len(bounds)} ? vec4(shapeBounds[index], 1.0) : vec4(0.0);
        return;
    }}
    int shape = index % {len(states)};
    int sampleIndex = index / {len(states)};
    int axis = sampleIndex % 3;
    float directionSign = (sampleIndex / 3) % 2 == 0 ? 1.0 : -1.0;
    float u = (float(sampleIndex % 127) + 0.37) / 127.0;
    float v = (float((sampleIndex / 127) % 127) + 0.19) / 127.0;
    vec3 origin;
    origin[axis] = directionSign > 0.0 ? -2.0 : 3.0;
    origin[(axis + 1) % 3] = u * 1.6 - 0.3;
    origin[(axis + 2) % 3] = v * 1.6 - 0.3;
    if (sampleIndex % 7 == 0) origin = vec3(.13,.37,.71) + u * .17;
    vec3 direction = vec3(0.0);
    direction[axis] = directionSign;
    ivec2 range = shapeRanges[shape];
    WorldShapeHit hit = worldIntersectShape(previous, range.x, range.y, 1024, ivec2(0),
        origin, direction, .00001, 100.0);
    result = vec4(hit.valid ? hit.distance : -1.0, hit.normal);
}}
''')
    binary = folder / 'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
                    str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    output = folder / 'shape-hits.raw'
    subprocess.run([str(binary),str(fragment),'1024','128','2','RGBA32F',str(output)],check=True)
    actual = np.fromfile(output,'<f4').reshape(-1,4)
    indices = np.arange(len(actual))
    origin,direction = rays(indices,len(states))
    expected = np.zeros_like(actual)
    for index,state in enumerate(states):
        selected = indices % len(states) == index
        expected[selected] = reference(state['boxes'],origin[selected],direction[selected])
    failures = np.flatnonzero(np.any(np.abs(actual-expected)>2e-4,axis=1))
    np.savez_compressed(folder/'reference.npz',origin=origin,direction=direction,expected=expected,actual=actual)
    (folder/'model-shapes.json').write_text(json.dumps(states,indent=2)+'\n')
    report = {'passed':len(failures)==0,'states':len(states),'rays':len(actual),'failed_rays':len(failures),
              'max_distance_error':float(np.max(np.abs(actual[:,0]-expected[:,0]))),
              'first_failures':[{'ray':int(i),'state':states[i%len(states)],'actual':actual[i].tolist(),
                                 'expected':expected[i].tolist()} for i in failures[:8]],
              'scope':'Native production intersection vs independent triangle oracle; not end-to-end state mapping'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['passed'],report
    print(f'{len(actual)} native rays across {len(states)} partial block states passed')


if __name__=='__main__':
    main()
