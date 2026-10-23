#!/usr/bin/env python3
"""Check canonical face equivalence and native choice moment decoding."""
import json
from pathlib import Path
import subprocess

import numpy as np

from world_choices import normalize

ROOT = Path(__file__).resolve().parents[1]


def metadata(row):
    return [(row['count'],row['channel']+row['choice_bit']*4,row['shift'],row['sum_bits']),
            (row['square_bits'],row['count_bits'],row['maximum_samples'],row['radix_multiplier']),
            (row['coverage_shift'],row['coverage_bits'],row['maximum_coverage'],row['fallback']+1)]


def check_surfaces(choices, surfaces):
    """Verify source membership and uncullable witnesses independently of packing."""
    original = json.loads((ROOT/'local-docs/migration/checkpoints/P04.2-raw/verified-native-pack/world-surfaces.json').read_text())
    canonical, remap = normalize(original)
    for source, index in zip(original['quads'], remap):
        target = canonical['quads'][index]
        expected = sorted(tuple(point+uv) for point,uv in zip(source['positions'],source['uv']))
        actual = sorted(tuple(point+uv) for point,uv in zip(target['positions'],target['uv']))
        assert expected == actual
        assert all(source[key] == target[key] for key in ('texture','tint','shade','normal'))
    assert all(len(source) == len(target) for source,target in zip(original['applications'],canonical['applications']))
    paths = 0
    fallbacks = 0
    for state in choices['states']:
        profile = choices['profiles'][state['profile']]
        references = {face:(condition,hint) for face,condition,hint in state['references']}
        for group,applications in enumerate(state['groups']):
            row = profile[group]
            assert len(applications) == row['count']
            for choice,application in enumerate(applications):
                faces = surfaces['applications'][application]
                cullable = surfaces['application_cullable'][application]
                sources = [(references[face][1],culled) for face,culled in zip(faces,cullable)]
                selected = [(hint,culled) for hint,culled in sources if 0 < hint < 128]
                assert all(hint//16-1 == group and hint%16 == choice for hint,_ in selected)
                assert len(selected) <= row['maximum_samples']
                if selected:
                    if row['fallback'] >= 0:
                        assert any(not culled for _,culled in selected)
                else:
                    assert row['fallback'] == choice
                if row['fallback'] >= 0:
                    coverage = [culled for hint,culled in sources if hint == 128+group]
                    assert coverage and all(not culled for culled in coverage)
                    assert len(coverage) <= row['maximum_coverage']
                bit = 1 << (row['choice_bit']+choice)
                observed = set(faces)
                for face,(condition,_) in references.items():
                    if condition >= 0:
                        assert bool(condition & bit) == (face in observed)
                paths += 1
            fallbacks += row['fallback'] >= 0
    return {'canonical_faces_checked':len(original['quads']), 'candidate_paths_checked':paths,
            'uncullable_fallback_proofs':fallbacks, 'layer_reference_counts_preserved':True}


def main():
    folder = ROOT/'local-docs/migration/runs/P04-choice-packing'
    folder.mkdir(parents=True,exist_ok=True)
    audit = ROOT/'local-docs/migration/runs/P04-choice-audit-v2'
    choices = json.loads((audit/'choices.json').read_text())
    surfaces = json.loads((audit/'surfaces.json').read_text())
    surface_report = check_surfaces(choices,surfaces)
    profiles = choices['profiles']
    flat = []
    ranges = []
    for profile in profiles:
        ranges.append((len(flat),len(profile)))
        flat.extend(profile)
    declarations = 'const ivec2 ranges[] = ivec2[]('+','.join('ivec2(%d,%d)'%row for row in ranges)+');\n'
    for index in range(3):
        declarations += 'const ivec4 words'+str(index)+'[] = ivec4[]('+','.join(
            'ivec4('+','.join(map(str,metadata(row)[index]))+')' for row in flat)+');\n'
    fragment = folder/'choices.frag'
    fragment.write_text('#version 330 core\n'+(ROOT/'shaders/lib/world/choice_packing.glsl').read_text()+declarations+f'''
layout(location=0) out vec4 result;
void main() {{
    int index = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 256;
    int profile = index % {len(profiles)};
    int sampleIndex = index / {len(profiles)};
    int kind = sampleIndex % 6;
    ivec2 range = ranges[profile];
    vec4 accumulation = vec4(0.0);
    int expected = 1;
    for (int entry = 0; entry < 6; entry++) {{
        if (entry >= range.y) break;
        int address = range.x + entry;
        WorldChoiceGroup group = worldChoiceGroup(words0[address],words1[address],words2[address]);
        int target = (sampleIndex * 73 + entry * 13) % group.count;
        expected += target * group.radix;
        if (kind == 0) {{
            if (target == group.fallback) accumulation += worldChoiceCoverage(group);
            else accumulation += worldChoiceContribution(group,target) * float(1 + sampleIndex % group.maximumSamples);
        }}
        if (kind == 1) accumulation += worldChoiceContribution(group,0) + worldChoiceContribution(group,1);
        if (kind == 3) accumulation += worldChoiceContribution(group,group.count - 1) * float(group.maximumSamples + 1);
        if (kind == 5 && group.fallback >= 0) accumulation += worldChoiceCoverage(group) * float(group.maximumCoverage + 1);
    }}
    if (kind == 4 && range.y > 0) accumulation.x += 0.5;
    if (kind != 0 && range.y > 0) expected = 0;
    int selected = 1;
    for (int entry = 0; entry < 6; entry++) {{
        if (entry >= range.y) break;
        int address = range.x + entry;
        WorldChoiceGroup group = worldChoiceGroup(words0[address],words1[address],words2[address]);
        int choice = worldDecodeChoice(accumulation,group);
        if (choice < 0) {{ selected = 0; break; }}
        selected += choice * group.radix;
    }}
    result = vec4(selected, expected, kind, profile);
}}
''')
    binary = folder/'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
                    str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    output = folder/'decoded.raw'
    subprocess.run([str(binary),str(fragment),'256','256','1','RGBA32F',str(output)],check=True)
    observed = np.fromfile(output,'<f4').reshape(-1,4)
    expected = []
    for index in range(len(observed)):
        sample = index // len(profiles)
        profile = profiles[index % len(profiles)]
        code = 1 + sum(((sample*73+entry*13) % row['count']) * row['radix_multiplier']
                       for entry,row in enumerate(profile))
        if sample % 6 != 0 and profile:
            code = 0
        expected.append(code)
    expected = np.array(expected)
    errors = int(np.count_nonzero(observed[:,0] != expected))
    internal_expected_errors = int(np.count_nonzero(observed[:,1] != expected))
    report = {'passed':errors == 0 and internal_expected_errors == 0,'profiles':len(profiles),
              'cases':len(observed),'decode_errors':errors,'independent_expected_errors':internal_expected_errors,
              'surface_proof':surface_report,
              'case_types':['Consistent witnesses and proven fallback','Conflicting choices','Missing observations',
                            'Count overflow','Fractional corruption','Coverage overflow'],
              'scope':'Native pure decoding kernel; mesh discovery, culling and updates require separate game validation'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
