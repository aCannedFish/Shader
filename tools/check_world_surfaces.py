#!/usr/bin/env python3
"""Verify the immutable surface directory and all shader metadata decoders."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

import numpy as np
from preview.source import expand
from world_surfaces import CORNERS, default_uv, face_uv, SURFACE_START
from check_world_choices import metadata

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pack', type=Path, default=ROOT/'local-docs/migration/prototypes/P04-surface-tables-v2/shaders')
    parser.add_argument('--output', type=Path, default=ROOT/'local-docs/migration/runs/P04-surface-resource-v2')
    args = parser.parse_args()
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    pack = args.pack.resolve()
    catalog = json.loads((pack/'world-definitions.json').read_text())
    choices = json.loads((pack/'world-choices.json').read_text())
    contract = catalog['surface_contract']
    conventions = json.loads((ROOT/'local-docs/migration/registry/face-conventions-v1/faces.json').read_text())
    for name, face in conventions.items():
        assert np.array_equal(CORNERS[name], face['corners']), name
        for degrees in (0, 90, 180, 270):
            expected = face['uv_rotations']['R'+str(degrees)]
            assert np.allclose(face_uv(default_uv([1,2,3], [11,13,15], name), degrees), expected), name
    records = np.fromfile(pack/'textures/world-static.bin', '<f4').reshape(-1,4)
    states, start, references, count = map(int, records[SURFACE_START])
    profile_start, offset_start, profile_count, offset_count = map(int, records[SURFACE_START+1])
    assert np.array_equal(records[SURFACE_START+2], [804,2,13,3])
    assert contract['end'] < len(records)-1
    assert start-states == len(catalog['states'])+1
    reference_count = contract['references']
    reference_words = records[references:references+(reference_count+1)//2].reshape(-1,2)[:reference_count]
    for state, selection in zip(catalog['states'],choices['states']):
        descriptor = records[states+state['id']]
        first, length = map(int,descriptor[:2])
        expected = np.array([[face*256+hint,condition] for face,condition,hint in selection['references']],dtype=np.float32).reshape(-1,2)
        assert np.array_equal(reference_words[first:first+length],expected), state['id']
        assert int(descriptor[2]) == selection['profile']
    for index, profile in enumerate(choices['profiles']):
        first, length, combinations, bits = map(int,records[profile_start+index])
        assert length == len(profile) and bits == sum(row['count'] for row in profile)
        assert combinations == int(np.prod([row['count'] for row in profile],dtype=np.int64))
        for group,row in enumerate(profile):
            assert np.array_equal(records[first+group*3:first+group*3+3],metadata(row))
    state_rows = records[states:states+contract['state_table_count']]
    offset_ranges = []
    offset_expected = []
    code_expected = []
    for profile in range(offset_count):
        material = next(index for index,row in enumerate(state_rows) if index>0 and int(row[3])==profile)
        counts = records[offset_start+profile*13,:3].astype(int)
        offset_ranges.append((len(offset_expected),int(np.prod(counts)),material))
        for sample in range(int(np.prod(counts))):
            code = np.array([sample%counts[0],(sample//counts[0])%counts[1],sample//(counts[0]*counts[1])])
            values = [records[offset_start+profile*13+1+axis*4+code[axis]//4,code[axis]%4] for axis in range(3)]
            offset_expected.append([*values,1])
            code_expected.append([*code,1])
    face_end = count*4
    state_end = face_end+len(catalog['states'])*3
    reference_end = state_end+reference_count
    offset_end = reference_end+len(offset_expected)*2
    width, height, _ = catalog['static_size']
    assert offset_end+4 <= width*height
    ranges = 'const ivec3 offsetRanges[] = ivec3[]('+','.join('ivec3(%d,%d,%d)'%row for row in offset_ranges)+');\n'
    source = '''#version 330 core
#include "/lib/world/model_surface.glsl"
#include "/lib/world/model_choices.glsl"
#include "/lib/world/model_offset.glsl"
uniform sampler2D previous;
layout(location=0) out vec4 result;
'''+ranges+f'''
void main() {{
    int index = int(gl_FragCoord.x) + int(gl_FragCoord.y) * {width};
    result = vec4(0.0);
    if (index < {face_end}) {{
        WorldModelFace face = worldModelFace(previous,index/4);
        if (index%4==0) result = vec4(face.a,face.texture*256+(face.tint+1)*16+int(face.shaded)*8+face.face);
        if (index%4==1) result = vec4(face.b,face.u.z);
        if (index%4==2) result = vec4(face.c,face.v.z);
        if (index%4==3) result = vec4(face.u.xy,face.v.xy);
    }} else if (index < {state_end}) {{
        int sample = index-{face_end};
        int material = sample/3+1;
        ivec4 range = worldModelChoiceRange(previous,material);
        if (sample%3==0) result = vec4(worldSurfaceState(previous,material));
        if (sample%3==1) result = vec4(range);
        if (sample%3==2) {{
            bool firstValid;
            bool lastValid;
            uint first = worldModelChoiceMask(previous,material,1,firstValid);
            uint last = worldModelChoiceMask(previous,material,range.z,lastValid);
            result = vec4(first,last,float(firstValid),float(lastValid));
        }}
    }} else if (index < {reference_end}) {{
        int address = index-{state_end};
        ivec2 reference = worldSurfaceReference(previous,address);
        result = vec4(worldSurfaceId(previous,address),reference.y,worldSurfaceHint(previous,address),0);
    }} else if (index < {offset_end}) {{
        int sample = (index-{reference_end})/2;
        for (int profile=0;profile<{offset_count};profile++) {{
            ivec3 range = offsetRanges[profile];
            if (sample < range.x || sample >= range.x+range.y) continue;
            int local = sample-range.x;
            int first = worldModelOffsetStart(previous,range.z);
            ivec3 counts = ivec3(round(worldStaticTexel(previous,first).xyz));
            ivec3 code = ivec3(local%counts.x,(local/counts.x)%counts.y,local/(counts.x*counts.y));
            WorldModelOffset offset = worldDecodeModelOffset(previous,range.z,code);
            if ((index-{reference_end})%2==0) result = vec4(offset.value,float(offset.valid));
            else {{
                WorldModelOffset found = worldFindModelOffset(previous,range.z,offset.value+vec3(.00003),.0005);
                result = vec4(found.code,float(found.valid));
            }}
        }}
    }} else if (index == {offset_end}) {{
        bool valid;
        uint mask = worldModelChoiceMask(previous,0,1,valid);
        result = vec4(mask,float(valid),float(worldDecodeModelOffset(previous,0,ivec3(0)).valid),0);
    }}
}}
'''
    fragment = folder/'surfaces.fsh'
    fragment.write_text(source)
    expanded = folder/'surfaces.frag'
    entry = pack/'.migration-surfaces-probe.fsh'
    shutil.copytree(ROOT/'shaders/lib/world',pack/'lib/world',dirs_exist_ok=True)
    try:
        entry.write_text(source)
        expanded.write_text(expand(entry,pack))
    finally:
        entry.unlink(missing_ok=True)
    binary = folder/'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
                    str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    output = folder/'decoded.raw'
    subprocess.run([str(binary),str(expanded),str(width),str(height),'1','RGBA32F',str(output),
                    str(pack/'textures/world-static.bin'),'RGBA32F'],check=True)
    decoded = np.fromfile(output,'<f4').reshape(-1,4)
    errors = {'faces':int(np.count_nonzero(decoded[:face_end] != records[start:start+face_end]))}
    gpu_states = decoded[face_end:state_end].reshape(-1,3,4)
    errors['state_directory'] = int(np.count_nonzero(gpu_states[:,0] != state_rows[1:]))
    expected_ranges = records[profile_start+state_rows[1:,2].astype(int)]
    errors['profile_directory'] = int(np.count_nonzero(gpu_states[:,1] != expected_ranges))
    expected_masks = []
    for row in state_rows[1:]:
        profile = choices['profiles'][int(row[2])]
        first = sum(1<<group['choice_bit'] for group in profile)
        last = sum(1<<(group['choice_bit']+group['count']-1) for group in profile)
        expected_masks.append([first,last,1,1])
    errors['choice_masks'] = int(np.count_nonzero(gpu_states[:,2] != expected_masks))
    expected_refs = np.column_stack((reference_words[:,0].astype(np.uint32)>>8,reference_words[:,1],
                                    reference_words[:,0].astype(np.uint32)&255,np.zeros(reference_count)))
    errors['references'] = int(np.count_nonzero(decoded[state_end:reference_end] != expected_refs))
    offsets = decoded[reference_end:offset_end].reshape(-1,2,4)
    errors['offset_values'] = int(np.count_nonzero(offsets[:,0] != np.array(offset_expected,dtype=np.float32)))
    errors['offset_reverse'] = int(np.count_nonzero(offsets[:,1] != code_expected))
    errors['invalid_material'] = int(np.count_nonzero(decoded[offset_end]))
    report = {'passed':not any(errors.values()),'faces':count,'state_lists':len(catalog['states']),
              'references':reference_count,'choice_profiles':profile_count,'offset_combinations':len(offset_expected),
              'errors':errors,'engine_uv_convention_cases':24,
              'static_texels_remaining':int(len(records)-1-contract['end']),
              'scope':'Native immutable resource/decoder verification; live model discovery is a separate game test'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__=='__main__':
    main()
