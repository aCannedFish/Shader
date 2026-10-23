#!/usr/bin/env python3
"""Report model coverage and geometry requirements before committing a layout."""
from collections import Counter
import json
from pathlib import Path
from world_assets import Assets

ROOT = Path(__file__).resolve().parents[1]


def main():
    definitions = json.loads((ROOT/'local-docs/migration/registry/vanilla-blocks.json').read_text())
    assets = Assets()
    missing = {}
    rotated = Counter()
    unresolved = {}
    maximum = 0
    processed = 0
    model_names = set()
    for block in definitions['blocks']:
        try:
            definition = assets.read('blockstates', block['name'])
        except FileNotFoundError:
            missing[block['name']] = sorted({state['render_shape'] for state in block['states']})
            continue
        for state in block['states']:
            choices = assets.applications(block['name'],state['properties'])
            if not choices:
                unresolved[block['name']] = state['properties']
            count = 0
            for application in choices:
                model_names.add(application['model'])
                model = assets.model(application['model'])
                elements = model.get('elements',[])
                count += len(elements)
                for element in elements:
                    rotation = element.get('rotation',{})
                    if rotation.get('angle',0):
                        rotated[(rotation['axis'],rotation['angle'],rotation.get('rescale',False))] += 1
            maximum = max(maximum,count)
            processed += 1
    report = {'registry_states':definitions['state_count'],'resolved_state_models':processed,
              'missing_blockstate_resources':missing,'unresolved_state_selectors':unresolved,
              'unique_model_names':len(model_names),'max_elements_all_alternatives':maximum,
              'rotations':[{'axis':key[0],'angle':key[1],'rescale':key[2],'uses':value} for key,value in rotated.items()]}
    folder = ROOT/'local-docs/migration/registry'
    (folder/'model-audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    main()
