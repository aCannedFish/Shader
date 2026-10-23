#!/usr/bin/env python3
"""Compare the production rotated-part kernel with independent triangle rays."""
import json
from pathlib import Path
import subprocess

import numpy as np
from check_world_shapes import triangles, rays
from world_assets import rotation
from world_catalog import SHAPE_START

ROOT = Path(__file__).resolve().parents[1]


def transform(part):
    code = int(part[9])
    angle = (0,22.5,-22.5,45,-45)[code%5]
    axis = (code%15)//5
    matrix = rotation(axis,angle)
    scale = np.ones(3)
    if code>=15:
        scale[(axis+1)%3] = scale[(axis+2)%3] = 1/np.cos(np.deg2rad(angle))
    return matrix,scale,np.array(part[6:9])


def triangle_reference(parts, origin, direction):
    if len(parts)==0:
        result = np.zeros((len(origin),4),np.float32)
        result[:,0] = -1
        return result
    faces = []
    normals = []
    planar = []
    for part in parts:
        local,normal = triangles([(part[:3],part[3:6])])
        matrix,scale,pivot = transform(part)
        faces.extend(((local-pivot)*scale) @ matrix.T + pivot)
        normals.extend(normal @ matrix.T)
        planar.extend([np.any(part[:3]==part[3:6])]*len(local))
    faces,normals,planar = np.array(faces),np.array(normals),np.array(planar)
    edge1,edge2 = faces[:,1]-faces[:,0],faces[:,2]-faces[:,0]
    p = np.cross(direction[:,None],edge2)
    determinant = np.sum(edge1*p,axis=-1)
    inverse = np.divide(1,determinant,out=np.zeros_like(determinant),where=abs(determinant)>1e-10)
    t = origin[:,None]-faces[:,0]
    u = np.sum(t*p,axis=-1)*inverse
    q = np.cross(t,edge1)
    v = np.sum(direction[:,None]*q,axis=-1)*inverse
    distance = np.sum(edge2*q,axis=-1)*inverse
    valid = (abs(determinant)>1e-10)&(u>=-1e-8)&(v>=-1e-8)&(u+v<=1+1e-8)&(distance>=1e-5)
    point = origin[:,None]+direction[:,None]*distance[...,None]
    before = point-direction[:,None]*2e-5
    after = point+direction[:,None]*2e-5
    inside_before = np.zeros(valid.shape,bool)
    inside_after = np.zeros(valid.shape,bool)
    for part in parts:
        matrix,scale,pivot = transform(part)
        local_before = ((before-pivot) @ matrix)/scale+pivot
        local_after = ((after-pivot) @ matrix)/scale+pivot
        inside_before |= np.all((local_before>part[:3])&(local_before<part[3:6]),axis=-1)
        inside_after |= np.all((local_after>part[:3])&(local_after<part[3:6]),axis=-1)
    valid &= (inside_before!=inside_after)|(planar[None]&~inside_before)
    candidates = np.where(valid,distance,np.inf)
    selected = candidates.argmin(axis=1)
    nearest = candidates[np.arange(len(origin)),selected]
    hit = np.isfinite(nearest)
    chosen_normals = normals[selected].copy()
    exits_volume = inside_before[np.arange(len(origin)),selected]
    points_along_ray = np.sum(chosen_normals*direction,axis=-1)>0
    # A decorative plane coincident with a solid boundary inherits the union's
    # exit orientation. An isolated sheet faces the incoming ray instead.
    flip = planar[selected] & (points_along_ray != exits_volume)
    chosen_normals[flip] *= -1
    result = np.zeros((len(origin),4),np.float32)
    result[:,0] = np.where(hit,nearest,-1)
    result[:,1:] = np.where(hit[:,None],chosen_normals,0)
    return result


def main():
    pack = ROOT/'local-docs/migration/prototypes/P04/shaders'
    catalog = json.loads((pack/'world-definitions.json').read_text())
    models = sorted({(state['first_box'],state['box_count']) for state in catalog['states']})
    folder = ROOT/'local-docs/migration/runs/P04-oriented-shapes'
    folder.mkdir(parents=True,exist_ok=True)
    fragment = folder/'models.frag'
    ranges = 'const ivec2 modelRanges[] = ivec2[]('+','.join(f'ivec2({first*3+SHAPE_START},{count})' for first,count in models)+');\n'
    fragment.write_text('#version 330 core\n'+(ROOT/'shaders/lib/world/shapes.glsl').read_text()+'\n'+ranges+f'''
uniform sampler2D previous;
layout(location=0) out vec4 result;
void main() {{
    int index = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 512;
    int model = index % {len(models)};
    int sampleIndex = index / {len(models)};
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
    ivec2 range = modelRanges[model];
    WorldShapeHit hit = worldIntersectShape(previous,range.x,range.y,512,3,ivec2(0),
        origin,direction,.00001,100.0);
    result = vec4(hit.valid ? hit.distance : -1.0,hit.normal);
}}
''')
    binary = folder/'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
        str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    output = folder/'model-hits.raw'
    subprocess.run([str(binary),str(fragment),'512','1024','1','RGBA32F',str(output),
        str(pack/'textures/world-static.bin'),'RGBA16F'],check=True)
    observed = np.fromfile(output,'<f4').reshape(-1,4)
    # Use the actual driver-decoded half values. Their error relative to the
    # resource definitions is measured by check_world_definitions separately.
    quantized = np.fromfile(ROOT/'local-docs/migration/runs/P04-definitions/decoded.raw','<f4').reshape(-1,4)
    indices = np.arange(len(observed))
    origins,directions = rays(indices,len(models))
    expected = np.zeros_like(observed)
    for model,(first,count) in enumerate(models):
        selected = indices%len(models)==model
        records = quantized[SHAPE_START+first*3:SHAPE_START+(first+count)*3].reshape(count,3,4)
        parts = np.concatenate((records[:,0,:3],records[:,1,:3],records[:,2,:]),axis=-1)
        expected[selected] = triangle_reference(parts,origins[selected],directions[selected])
    failures = np.flatnonzero(np.any(abs(observed-expected)>.0002,axis=1))
    report = {'passed':len(failures)==0,'models':len(models),'rays':len(observed),'failed_rays':len(failures),
              'first_failures':[{'ray':int(index),'model':models[index%len(models)],
                                'expected':expected[index].tolist(),'actual':observed[index].tolist()} for index in failures[:12]],
              'scope':'All encoded candidate unions, rotated elements, rescale and planes; live weighted variant choice is separate'}
    np.savez_compressed(folder/'reference.npz',observed=observed,expected=expected)
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['passed'],report
    print(f'{len(observed)} rays across {len(models)} model unions passed')


if __name__=='__main__':
    main()
