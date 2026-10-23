#!/usr/bin/env python3
"""Verify actual J9 state observations, static tables and rendered-surface queries."""
import argparse
import json
from pathlib import Path
import shutil

import numpy as np
from check_world_capture import decode_int

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', default='shape-queries-fixed')
    args = parser.parse_args()
    game = ROOT / '.preview' / ('game-' + args.run)
    source = game / 'screenshots'
    destination = ROOT / 'local-docs/migration/runs' / ('P03-' + args.run)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination / 'screenshots', dirs_exist_ok=True)
    pack = game / 'shaderpacks/SimpleShader/shaders'
    for file in ('world-layout.json','world-fixture.json'):
        shutil.copy2(pack / file, destination / file)
    for file in ('capture.log','isolation.json'):
        shutil.copy2(ROOT / '.preview' / ('captures-' + args.run) / file, destination / file)
    contract = json.loads((pack / 'world-layout.json').read_text())
    fixture = json.loads((pack / 'world-fixture.json').read_text())
    name = 'migration_shapes'
    info = json.loads((source / (name + '-world.json')).read_text())
    arrays = {}
    for field in ('header','states','shapes','far_optics'):
        region = contract['persistent']['regions'][field]
        arrays[field] = np.fromfile(source/(name+'-'+field+'.raw'),'<f4').reshape(region['height'],region['width'],4)
    header = arrays['header'][0]
    origin = np.array([decode_int(value) for value in header[5:8]])
    shape = np.array(contract['far_shape'])
    actual = np.array(info['actual_camera_readback_only'])
    offset = np.floor(actual / 4).astype(int)*4 - shape//2 - origin
    failures = []
    samples = []
    for state in fixture['states']:
        cell = np.array(state['position']) - offset - origin
        x,y,z = cell
        optics = arrays['far_optics'][y+z//8*shape[1],x+z%8*shape[0]]
        material = int(round(float(optics[0]+optics[1]*256)))
        descriptor = arrays['states'].reshape(-1,4)[state['material']*contract.get('state_stride',2)]
        first = int(round(float(descriptor[0] + (int(descriptor[1]) & 31) * 2048))) if contract.get('schema_version',1)>=2 else int(round(float(descriptor[0]+descriptor[1]*256)))
        count = int(round(float(descriptor[2])))
        stride = contract.get('shape_stride',2)
        bounds = arrays['shapes'].reshape(-1,4)[first*stride:(first+count)*stride].reshape(count,stride,4)[:,:2,:3].reshape(-1,3)
        expected = np.array([point for box in state['boxes'] for point in box])
        passed = material == state['material'] and count == state['box_count'] and first == state['first_box']
        passed = passed and bounds.shape == expected.shape and bool(np.allclose(bounds,expected,atol=1e-7))
        row = {'block':state['block'],'properties':state['properties'],'expected_id':state['material'],
               'observed_id':material,'first_box':first,'box_count':count,'passed':passed}
        samples.append(row)
        if not passed:
            failures.append(row)
    queries = np.fromfile(source/(name+'-surface-query.raw'),'<f4').reshape(-1,4)
    selected = np.isin(queries[:,0], [state['material'] for state in fixture['states']])
    observed = queries[selected]
    query_errors = (observed[:,1]<0) | (np.abs(observed[:,1]-observed[:,2])>.008)
    image = queries.reshape(info['query_height'], info['query_width'], 4)
    boundary = np.zeros(image.shape[:2], bool)
    for dx,dy in ((-1,0),(1,0),(0,-1),(0,1)):
        neighbour = np.roll(image, (dy,dx), (0,1))
        boundary |= neighbour[...,0] != image[...,0]
    edge_queries = boundary.reshape(-1)[selected]
    interior_errors = int(np.count_nonzero(query_errors & ~edge_queries))
    hit_rate = 1.0 - np.count_nonzero(query_errors) / max(len(observed), 1)
    # The plan allows a separate raster outline band, while keeping its failed
    # pixels in the overall hit rate. No edge pixel is excluded from statistics.
    native_passed = len(observed)>100 and hit_rate>=.99 and interior_errors==0
    table_report = None
    if (pack/'world-definitions.json').is_file():
        catalog = json.loads((pack/'world-definitions.json').read_text())
        native_table = arrays['states'].reshape(-1,4)
        original = np.fromfile(pack/'textures/world-static.bin','<f4').reshape(-1,4)[:len(native_table)]
        rounded = original.astype(np.float16)
        lower = np.nextafter(rounded,np.float16(-np.inf)).astype(np.float32)
        upper = np.nextafter(rounded,np.float16(np.inf)).astype(np.float32)
        mismatches = np.count_nonzero((native_table<lower)|(native_table>upper))
        # All geometry identity, level/alpha codes and flag fields are integers
        # bounded by 2047 and must remain exact in the real J9 cache.
        integer_mask = np.zeros_like(original,dtype=bool)
        integer_mask[::3] = True
        integer_mask[1::3,3] = True
        integer_mask[2::3,3] = True
        integer_errors = np.count_nonzero(native_table[integer_mask]!=original[integer_mask])
        table_report = {'states':len(catalog['states']),'coefficient_errors':int(mismatches),
                        'integer_errors':int(integer_errors),'passed':bool(mismatches==0 and integer_errors==0)}
        native_passed = native_passed and table_report['passed']
    report = {'passed':not failures and native_passed,'full_definition_table':table_report,
              'states':len(samples),'state_mapping_failures':failures,'samples':samples,
              'native_surface_queries':len(observed),'surface_query_failures':int(np.count_nonzero(query_errors)),
              'surface_hit_rate_including_edges':float(hit_rate),
              'edge_failures_included':int(np.count_nonzero(query_errors & edge_queries)),
              'interior_failures':interior_errors,
              'unknown_screen_queries':int(np.count_nonzero(queries[:,0]<0)),
              'full_screen_pixels':len(queries),
              'thresholds':{'minimum_hit_rate':.99,'maximum_interior_failures':0,'distance_tolerance_blocks':.008},
              'surface_distance_p99':float(np.percentile(np.abs(observed[:,1]-observed[:,2]),99)) if len(observed) else None,
              'query_materials':sorted(np.unique(observed[:,0].astype(int)).tolist()),
              'scope':'Native state/table readback and real rendered-depth ray queries; alpha continuation tested separately in P04'}
    (destination/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    if not report['passed']:
        print(json.dumps({key:value for key,value in report.items() if key != 'samples'},indent=2))
        raise SystemExit(1)
    print(f"{len(samples)} states and {len(observed)} native surface queries passed")


if __name__=='__main__':
    main()
