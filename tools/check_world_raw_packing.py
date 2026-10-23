#!/usr/bin/env python3
"""Verify finite-float raw payloads through two native RGBA32F render passes."""
import json
from pathlib import Path
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = ROOT/'local-docs/migration/runs/P04-raw-packing'
    output.mkdir(parents=True, exist_ok=True)
    common = '#version 330 core\n'+(ROOT/'shaders/lib/world/raw_packing.glsl').read_text()
    encode = output/'encode.frag'
    encode.write_text(common+'''
layout(location=0) out vec4 result;
uint payload(uint index, uint channel) {
    uint value = (index + 1u) * 2654435761u + channel * 2246822519u;
    value ^= value >> 16u;
    if (index == 0u) value = 0u;
    if (index == 1u) value = 0x3fffffffu;
    return value & 0x3fffffffu;
}
void main() {
    uint index = uint(int(gl_FragCoord.x) + int(gl_FragCoord.y) * 384) / 3u;
    uvec4 words = uvec4(payload(index,0u),payload(index,1u),payload(index,2u),payload(index,3u));
    result = worldRawEncode(words, index % 17u != 2u, index % 2u == 1u);
}
''')
    decode = output/'decode.frag'
    decode.write_text(common+'''
uniform sampler2D previous;
layout(location=0) out vec4 result;
void main() {
    int pixel = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 384;
    int first = pixel / 3 * 3;
    vec4 encoded = texelFetch(previous,ivec2(first % 384, first / 384),0);
    bool valid = worldRawValid(encoded);
    uvec4 words = valid ? worldRawDecode(encoded) : uvec4(0u);
    if (pixel % 3 == 0) result = vec4(words.x & 32767u, words.x >> 15u, words.y & 32767u, words.y >> 15u);
    if (pixel % 3 == 1) result = vec4(words.z & 32767u, words.z >> 15u, words.w & 32767u, words.w >> 15u);
    if (pixel % 3 == 2) result = vec4(float(valid), float(encoded.x < 0.0), 0.0, 1.0);
}
''')
    binary = output/'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
                    str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    packed = output/'packed.raw'
    decoded = output/'decoded.raw'
    subprocess.run([str(binary),str(encode),'384','128','1','RGBA32F',str(packed)],check=True)
    subprocess.run([str(binary),str(decode),'384','128','1','RGBA32F',str(decoded),str(packed),'RGBA32F'],check=True)
    values = np.fromfile(decoded,'<f4').reshape(-1,3,4)
    indices = np.arange(len(values),dtype=np.uint64)
    channels = np.arange(4,dtype=np.uint64)
    words = ((indices[:,None]+1)*2654435761+channels*2246822519) & 0xffffffff
    words ^= words >> 16
    words[0] = 0
    words[1] = 0x3fffffff
    words &= 0x3fffffff
    valid = indices % 17 != 2
    observed = values[:,:2].reshape(-1,4,2).astype(np.uint64)
    observed = observed[...,0] | (observed[...,1] << 15)
    errors = int(np.count_nonzero(observed[valid] != words[valid]))
    packed_words = np.fromfile(packed,'<u4').reshape(-1,3,4)[:,0]
    expected_bits = (((words >> 23)+1) << 23) | (words & 0x007fffff)
    expected_bits[:,3] |= 0x80000000
    expected_bits[indices%2 == 1,0] |= 0x80000000
    errors += int(np.count_nonzero(packed_words[valid] != expected_bits[valid]))
    flags_valid = np.array_equal(values[:,2,0],valid) and np.array_equal(values[valid,2,1],indices[valid]%2)
    report = {'passed':errors == 0 and flags_valid,'records':len(values),'payload_bits_per_record':120,
              'integer_or_raw_bit_errors':errors,'invalid_records_preserved':int(np.count_nonzero(~valid)),
              'zero_and_max_payloads_verified':bool(np.array_equal(observed[:2],words[:2])),
              'scope':'Native RGBA32F unit roundtrip; indexed shadow blending requires a separate J9 test'}
    (output/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
