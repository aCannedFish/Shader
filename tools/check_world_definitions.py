#!/usr/bin/env python3
"""Verify all registry definitions through half-float storage and production GLSL."""
from collections import Counter
import json
from pathlib import Path
import subprocess

import numpy as np
from world_catalog import build, STATE_CAPACITY, STATE_STRIDE, SHAPE_START, SHAPE_STRIDE

ROOT = Path(__file__).resolve().parents[1]


def main():
    pack = ROOT/'local-docs/migration/prototypes/P04/shaders'
    catalog = build(pack)
    folder = ROOT/'local-docs/migration/runs/P04-definitions'
    folder.mkdir(parents=True,exist_ok=True)
    fragment = folder/'definitions.frag'
    fragment.write_text('#version 330 core\n'+(ROOT/'shaders/lib/world/definition.glsl').read_text()+f'''
uniform sampler2D previous;
layout(location=0) out vec4 result;
vec4 source(int index) {{
    return texelFetch(previous, ivec2(index % 512, index / 512), 0);
}}
void main() {{
    int index = int(gl_FragCoord.x) + int(gl_FragCoord.y) * 512;
    result = source(index);
    int state = index / {STATE_STRIDE};
    if (state > 0 && state <= {len(catalog['states'])} && index < {SHAPE_START}) {{
        WorldDefinition definition = worldDecodeDefinition(source(state*3), source(state*3+1), source(state*3+2));
        int word = index % 3;
        if (word == 0) result = vec4(definition.firstBox, definition.boxCount, definition.legacy, definition.flags);
        if (word == 1) result = vec4(definition.emission, definition.emissionLevel);
        if (word == 2) result = vec4(definition.absorption, definition.alphaType);
    }}
}}
''')
    binary = folder/'world-probe'
    subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
                    str(ROOT/'tools/preview/world_probe.c'),'-o',str(binary)],check=True)
    output = folder/'decoded.raw'
    subprocess.run([str(binary),str(fragment),'512','1024','1','RGBA32F',str(output),
                    str(pack/'textures/world-static.bin'),'RGBA16F'],check=True)
    observed = np.fromfile(output,'<f4').reshape(-1,4)
    failures = []
    inactive = 0
    maximum_relative_error = 0.0
    for state in catalog['states']:
        index = state['id']*3
        expected = np.array([[state['first_box'],state['box_count'],state['legacy'],state['flags']],
                             [*state['emission_rgb'],state['emission']],
                             [*state['absorption'],state['alpha']]],np.float32)
        # Integer identity must be exact. Spectral coefficients retain their
        # actual half-float quantization, checked separately from geometry IDs.
        actual = observed[index:index+3]
        exact = np.array_equal(actual[0],expected[0]) and np.array_equal(actual[1:,3],expected[1:,3])
        rounded = expected[1:,:3].astype(np.float16)
        lower = np.nextafter(rounded,np.float16(-np.inf)).astype(np.float32)
        upper = np.nextafter(rounded,np.float16(np.inf)).astype(np.float32)
        # OpenGL texture conversion may choose the adjacent representable half
        # instead of IEEE round-to-nearest. Check the actual one-ULP envelope.
        spectral = np.all((actual[1:,:3]>=lower)&(actual[1:,:3]<=upper))
        positive = expected[1:,:3]>0
        if np.any(positive):
            relative = abs(actual[1:,:3][positive]-expected[1:,:3][positive])/expected[1:,:3][positive]
            maximum_relative_error = max(maximum_relative_error,float(relative.max()))
        if not exact or not spectral:
            failures.append({'id':state['id'],'block':state['block'],'expected':expected.tolist(),'actual':actual.tolist()})
        if state['emission']==0:
            assert np.all(actual[1,:3]==0),state
            inactive += 1
    original = np.fromfile(pack/'textures/world-static.bin','<f4').reshape(-1,4)
    start,end = SHAPE_START,SHAPE_START+catalog['shape_parts']*SHAPE_STRIDE
    shapes = observed[start:end]
    assert np.all(np.isfinite(shapes))
    shape_error = float(np.max(abs(shapes-original[start:end])))
    assert shape_error<.001
    definitions = json.loads((ROOT/'local-docs/migration/registry/vanilla-blocks.json').read_text())
    assert len(catalog['states'])==definitions['state_count']
    assert len({state['id'] for state in catalog['states']})==len(catalog['states'])
    assert all(0<=state['flags']<131072 and 0<=state['box_count']<=64 for state in catalog['states'])
    report = {'passed':not failures,'states':len(catalog['states']),'blocks':len(catalog['defaults']),
              'inactive_emitters_zero_rgb':inactive,'integer_or_spectral_failures':failures,
              'shape_parts':catalog['shape_parts'],'unique_shapes':catalog['unique_shapes'],
              'maximum_shape_quantization_error':shape_error,
              'maximum_spectral_relative_error':maximum_relative_error,
              'spectral_tolerance':'At most one adjacent representable half value; all integer fields exact',
              'alpha_types':dict(Counter(state['alpha'] for state in catalog['states'])),
              'geometry_alternative_states':sum(bool(state['flags']&16) for state in catalog['states']),
              'scope':'Actual OpenGL decode of all immutable state records, not native J9 alias/geometry validation'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['passed'],failures[:5]
    print(json.dumps({key:value for key,value in report.items() if key!='integer_or_spectral_failures'},indent=2))


if __name__=='__main__':
    main()
