"""Generate static block-state and model-shape data shipped inside the shader ZIP.

This file builds resource definitions only. Live world observations still come
exclusively from the shadow geometry stage; no test helper uploads them.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
from world_assets import Assets, shape_fixture

STATE_COUNT = 32768
STATE_TEXELS = STATE_COUNT * 3
SHAPE_TEXELS = 512 * 384
STATIC_SIZE = (128,64,64)


def build_fixture(target, original_properties):
    states = shape_fixture(Assets())
    records = np.zeros((np.prod(STATIC_SIZE),4),'<f4')
    records[:STATE_TEXELS:3,2] = 1
    records[:3072:3,3] = np.arange(1024)
    records[110*3+1,3] = 32
    boxes = [((0,0,0),(1,1,1))]
    known_shapes = {tuple(boxes): 0}
    overridden = {state['block'] for state in states}
    filtered = []
    for line in original_properties.splitlines():
        if line.startswith('block.') and '=' in line:
            key, values = line.split('=', 1)
            tokens = [token for token in values.split()
                      if token.split(':')[1] not in overridden]
            line = key + '= ' + ' '.join(tokens)
        filtered.append(line)
    aliases = ['\n'.join(filtered), '\n# Generated immutable model-state mappings.\n']
    for index,state in enumerate(states):
        material = 4096 + index
        shape = tuple(state['boxes'])
        if shape not in known_shapes:
            known_shapes[shape] = len(boxes)
            boxes.extend(shape)
        first = known_shapes[shape]
        legacy = 110 if state['block'] == 'glass_pane' else 0
        records[material*3] = (first % 2048, first // 2048, len(shape), legacy)
        records[material*3+1,3] = 32 if legacy == 110 else 0
        state.update(material=material, first_box=first, box_count=len(shape))
        selector = 'minecraft:' + state['block'] + ''.join(
            ':'+key+'='+value for key,value in sorted(state['properties'].items()))
        aliases.append(f'block.{material} = {selector}\n')
        state['position'] = [2800 + (index % 14)*2, 201, 2800 + (index//14)*2]
    bounds = np.array([(*point,0) for box in boxes for point in (*box,(0,0,0))],'<f4')
    assert len(bounds) <= SHAPE_TEXELS
    records[STATE_TEXELS:STATE_TEXELS+len(bounds)] = bounds
    stamp = hashlib.sha256(records.tobytes()).digest()[:4]
    records[-1] = list(stamp)
    texture = target/'textures/world-static.bin'
    texture.parent.mkdir(parents=True,exist_ok=True)
    texture.write_bytes(records.tobytes())
    (target/'block.properties').write_text(''.join(aliases))
    fixture = {'schema_version':1,'states':states,'unique_shapes':len(known_shapes),
               'boxes':len(boxes),'static_sha256':hashlib.sha256(texture.read_bytes()).hexdigest()}
    (target/'world-fixture.json').write_text(json.dumps(fixture,indent=2)+'\n')
    return fixture
