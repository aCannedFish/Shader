#!/usr/bin/env python3
"""Verify J9 indexed accumulation, unblended payloads and zero-alpha writes."""
import argparse
import json
from pathlib import Path
import shutil

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', default='p04-shadow-blend-v3')
    args = parser.parse_args()
    game = ROOT/'.preview'/('game-'+args.run)
    source = game/'screenshots'
    pack = game/'shaderpacks/SimpleShader/shaders'
    destination = ROOT/'local-docs/migration/runs'/('P04-blend-'+args.run)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination/'screenshots', dirs_exist_ok=True)
    for name in ('capture.log','isolation.json'):
        shutil.copy2(ROOT/'.preview'/('captures-'+args.run)/name, destination/name)
    layout = json.loads((pack/'world-layout.json').read_text())
    region = layout['persistent']['regions']['header']
    expected = np.array([0x01234567,0x23456789,0x3456789a,0x3fffffff],dtype=np.uint64)
    scenes = []
    for scene in ('migration_shapes','migration_atlas_reload'):
        header = np.fromfile(source/(scene+'-header.raw'),'<f4').reshape(region['height'],region['width'],4)[0]
        payload = np.zeros(4,dtype=np.uint64)
        zero_payload = np.zeros(4,dtype=np.uint64)
        for byte in range(4):
            payload |= header[33+byte].astype(np.uint64) << (byte*8)
            zero_payload |= header[40+byte].astype(np.uint64) << (byte*8)
        accumulation = header[32]
        count = float(accumulation[0])
        additive = count>=2 and np.array_equal(accumulation,np.array([count,count*2,count*3,0]))
        clear_zero = bool(np.all(header[38]==0))
        zero_output = bool(np.all(header[39]==0))
        exact = np.array_equal(payload,expected) and np.array_equal(zero_payload,expected)
        flags = np.array_equal(header[37],[1,1,719,1]) and np.array_equal(header[44],[1,1,720,1])
        scenes.append({'scene':scene,'accumulated_contributions':count,'attachment_zero_additive':bool(additive),
                       'attachment_one_bit_exact':bool(exact),'clear_is_zero':clear_zero,
                       'zero_colour_and_alpha_preserve_payload':bool(zero_output and exact),
                       'passed':bool(additive and exact and flags and clear_zero and zero_output)})
    report = {'passed':all(row['passed'] for row in scenes),'scenes':scenes,
              'required_configuration':['Global shadow blend lock','Indexed attachment one blend disabled',
                                        'Shadow clear colour declared in prepare/composite stage'],
              'scope':'Native J9 collection capability; no model-choice producer or renderer performance claim'}
    (destination/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
