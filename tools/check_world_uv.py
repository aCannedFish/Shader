#!/usr/bin/env python3
"""Verify affine UV packing through native half-float or raw-float targets."""
import json
import argparse
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--raw', action='store_true')
    args = parser.parse_args()
    folder = (args.output or ROOT/'local-docs/migration/runs'/('P04-raw-uv' if args.raw else 'P04-uv-codec-v3')).resolve()
    folder.mkdir(parents=True,exist_ok=True)
    header = '#version 330 core\n'+(ROOT/'shaders/lib/world/uv.glsl').read_text()
    if args.raw:
        header += (ROOT/'shaders/lib/world/raw_packing.glsl').read_text()
        header += '\n'.join(line for line in (ROOT/'shaders/lib/world/raw_uv.glsl').read_text().splitlines()
                            if not line.startswith('#include'))+'\n'
    encode = folder/'encode.frag'
    encode.write_text(header+'''
layout(location=0) out vec4 result;
void main() {
    int index = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 384;
    int record = index / 3;
    float a = float((record * 73) % 8192 - 4096) / 4096.0;
    float b = float((record * 151) % 8192 - 4096) / 8192.0;
    if (record % 257 == 0) a = 1.999999;
    if (record % 251 == 0) b = -1.999999;
    WorldUv value = WorldUv(vec3(a,b,.37),vec3(b,-a,.63),record % 17 != 0, record % 2 == 1);
    result = worldEncodeUvWord(value,index % 3);
}
''')
    if args.raw:
        encode.write_text(encode.read_text().replace('worldEncodeUvWord(value,index % 3)', 'worldRawEncodeUv(value)'))
    decode = folder/'decode.frag'
    decode.write_text(header+'''
uniform sampler2D previous;
layout(location=0) out vec4 result;
vec4 source(int index) { return texelFetch(previous,ivec2(index%384,index/384),0); }
void main() {
    int index = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 384;
    int first = index / 3 * 3;
    WorldUv value = worldDecodeUv(source(first),source(first+1),source(first+2));
    if (index%3==0) result = vec4(value.u,float(value.valid));
    if (index%3==1) result = vec4(value.v,float(value.tinted));
    if (index%3==2) result = vec4(worldSurfaceUv(value,vec2(.325,.825)),0,1);
}
''')
    if args.raw:
        decode.write_text(decode.read_text().replace('worldDecodeUv(source(first),source(first+1),source(first+2))',
                                                    'worldRawDecodeUv(source(first))'))
    binary = folder/'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
        str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    packed = folder/'packed.raw'
    output = folder/'decoded.raw'
    storage = 'RGBA32F' if args.raw else 'RGBA16F'
    subprocess.run([str(binary),str(encode),'384','128','1',storage,str(packed)],check=True)
    subprocess.run([str(binary),str(decode),'384','128','1','RGBA32F',str(output),str(packed),storage],check=True)
    values = np.fromfile(output,'<f4').reshape(-1,3,4)
    indices = np.arange(len(values))
    valid = indices%17 != 0
    a = ((indices*73)%8192-4096)/4096
    b = ((indices*151)%8192-4096)/8192
    a[indices%257 == 0] = 1.999999
    b[indices%251 == 0] = -1.999999
    expected_u = np.stack((a,b,np.full(len(a),.37)),axis=-1)
    expected_v = np.stack((b,-a,np.full(len(a),.63)),axis=-1)
    assert np.array_equal(values[:,0,3],valid)
    assert np.array_equal(values[valid,1,3],indices[valid]%2)
    coefficient_error = max(np.max(abs(values[valid,0,:3]-expected_u[valid])),np.max(abs(values[valid,1,:3]-expected_v[valid])))
    expected_uv = np.stack((expected_u @ np.array([.325,.825,1]),expected_v @ np.array([.325,.825,1])),axis=-1)
    point_error = float(np.max(abs(values[valid,2,:2]-expected_uv[valid])))
    assert coefficient_error<.000004 and point_error<.00001
    report = {'passed':True,'records':len(values),'invalid_records_preserved':int(np.count_nonzero(~valid)),
              'max_coefficient_error':float(coefficient_error),'max_point_uv_error':point_error,
              'storage':storage,
              'scope':'Native UV encoding/decoding; live surface association is separate'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    main()
