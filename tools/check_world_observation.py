#!/usr/bin/env python3
"""Verify the single-attachment observation record and positive half colours."""
import json
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    folder = ROOT/'local-docs/migration/runs/P04-observation-codec-v2'
    folder.mkdir(parents=True,exist_ok=True)
    header = '#version 330 core\n'+(ROOT/'shaders/lib/world/raw_packing.glsl').read_text()
    header += '\n'.join(line for line in (ROOT/'shaders/lib/world/raw_observation.glsl').read_text().splitlines()
                        if not line.startswith('#include'))+'\n'
    encode = folder/'encode.frag'
    encode.write_text(header+'''
layout(location=0) out vec4 result;
void main() {
    int index = (int(gl_FragCoord.x)+int(gl_FragCoord.y)*512)/4;
    vec3 colour = vec3(float(index%8192)/4096.0,
        uintBitsToFloat((uint(index%41+96)<<23u) | ((uint(index)*67867967u)&0x007fffffu)),
        float((index*101)%8192)/8192.0);
    if (index==0) colour = vec3(0.0,1.00048828125,uintBitsToFloat(0x33000000u));
    if (index==1) colour = vec3(65504.0,1000000.0,uintBitsToFloat(0x33000001u));
    WorldObservation observation = WorldObservation(index==1 ? 32767 : index%32767+1,
        index%6,(index*37)%256,ivec3(index%16,(index*3)%16,(index*7)%16),index%2==1,index%3!=0,
        vec3(index%256,(index*73)%256,(index*151)%256)/255.0,colour);
    if (index>=8 && index%17==2) observation.material = 0;
    if (index>=8 && index%23==5) observation.albedo.g = uintBitsToFloat(0x7fc00000u);
    if (index>=8 && index%29==7) observation.face = 6;
    if (index>=8 && index%31==11) observation.offsetCode.x = 16;
    result = worldEncodeObservation(observation);
    if (index>=8 && index%19==3 && worldRawValid(result)) {
        uvec4 words = worldRawDecode(result);
        words.w ^= 1u<<22u;
        result = worldRawEncode(words,true,false);
    }
}
''')
    decode = folder/'decode.frag'
    decode.write_text(header+'''
uniform sampler2D previous;
layout(location=0) out vec4 result;
void main() {
    int pixel = int(gl_FragCoord.x)+int(gl_FragCoord.y)*512;
    int first = pixel/4*4;
    WorldObservation value = worldDecodeObservation(texelFetch(previous,ivec2(first%512,first/512),0));
    if (pixel%4==0) result = vec4(value.material,value.face,value.light,float(value.offsetValid));
    if (pixel%4==1) result = vec4(value.offsetCode,float(value.material>0));
    if (pixel%4==2) result = vec4(value.albedo,0.0);
    if (pixel%4==3) result = vec4(value.tint,float(value.tintValid));
}
''')
    binary = folder/'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
                    str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    packed = folder/'packed.raw'
    decoded = folder/'decoded.raw'
    subprocess.run([str(binary),str(encode),'512','128','1','RGBA32F',str(packed)],check=True)
    subprocess.run([str(binary),str(decode),'512','128','1','RGBA32F',str(decoded),str(packed),'RGBA32F'],check=True)
    actual = np.fromfile(decoded,'<f4').reshape(-1,4,4)
    indices = np.arange(len(actual),dtype=np.uint64)
    valid = (indices<8) | ((indices%17!=2)&(indices%19!=3)&(indices%23!=5)&(indices%29!=7)&(indices%31!=11))
    expected = np.zeros_like(actual)
    materials = indices%32767+1
    materials[1] = 32767
    expected[:,0] = np.column_stack((materials,indices%6,(indices*37)%256,indices%2))
    expected[:,1] = np.column_stack((indices%16,(indices*3)%16,(indices*7)%16,np.ones(len(indices))))
    bits = (((indices%41+96)<<23) | ((indices*67867967)&0x007fffff)).astype('<u4')
    colour = np.column_stack(((indices%8192)/4096.0,bits.view('<f4'),((indices*101)%8192)/8192.0)).astype('<f4')
    colour[0] = [0,1.00048828125,np.array([0x33000000],'<u4').view('<f4')[0]]
    colour[1] = [65504,1000000,np.array([0x33000001],'<u4').view('<f4')[0]]
    expected[:,2,:3] = np.clip(colour,0,65504).astype(np.float16).astype(np.float32)
    expected[:,3,:3] = np.column_stack((indices%256,(indices*73)%256,(indices*151)%256))/255.0
    expected[:,3,3] = indices%3 != 0
    expected[~valid] = 0
    exact_errors = int(np.count_nonzero(actual[:,:3] != expected[:,:3]))
    tint_error = float(np.max(abs(actual[:,3]-expected[:,3])))
    report = {'passed':exact_errors==0 and tint_error<1e-7,'records':len(actual),
              'invalid_records_rejected':int(np.count_nonzero(~valid)),
              'metadata_or_half_colour_errors':exact_errors,'maximum_tint_error':tint_error,
              'half_rounding': 'Independent NumPy binary16 reference, including subnormal ties and saturation',
              'scope':'Native raw observation codec; source geometry integration requires a separate game test'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if not report['passed']:
        np.save(folder/'mismatched-records.npy',np.where(np.any(actual[:,:3]!=expected[:,:3],axis=(1,2)))[0])
        raise SystemExit(1)


if __name__=='__main__':
    main()
