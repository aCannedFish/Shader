"""Compile individual immutable model faces without merging coincident layers.

Bounds alone cannot distinguish fence posts, crossbars or grass overlays. These
records retain each quad's position, texture identity, tint and model choice.
Atlas coordinates are learned by the GPU from actual submitted primitives.
"""
import json
import math
from pathlib import Path

import numpy as np

from world_assets import Assets, rotation, selector_matches, parse_variant

ROOT = Path(__file__).resolve().parents[1]
SURFACE_START = 294912

# Minecraft face winding, checked against the matching game's FaceInfo class.
CORNERS = {
    'down': ((0,0,1),(0,0,0),(1,0,0),(1,0,1)),
    'up': ((0,1,0),(0,1,1),(1,1,1),(1,1,0)),
    'north': ((1,1,0),(1,0,0),(0,0,0),(0,1,0)),
    'south': ((0,1,1),(0,0,1),(1,0,1),(1,1,1)),
    'west': ((0,1,0),(0,0,0),(0,0,1),(0,1,1)),
    'east': ((1,1,1),(1,0,1),(1,0,0),(1,1,0)),
}


def default_uv(low, high, face):
    """Return logical sprite UVs before explicit face and model rotations."""
    x,y,z = low
    xx,yy,zz = high
    rectangle = {
        'down': (x,16-zz,xx,16-z), 'up': (x,z,xx,zz),
        'north': (16-xx,16-yy,16-x,16-y), 'south': (x,16-yy,xx,16-y),
        'west': (z,16-yy,zz,16-y), 'east': (16-zz,16-yy,16-z,16-y),
    }[face]
    return np.array(rectangle, float) / 16


def face_uv(rectangle, degrees):
    u,v,uu,vv = rectangle
    points = np.array(((u,v),(u,vv),(uu,vv),(uu,v)))
    return np.roll(points, -(degrees // 90), axis=0)


def locked_uv(uv, face, transform):
    """Apply UV lock to actual coordinates, including cropped face rectangles."""
    corners = np.array(((0,0),(0,1),(1,1),(1,0)),float)
    unit = (np.array(CORNERS[face],float)-.5) @ transform.T + .5
    normal = np.cross(unit[1]-unit[0],unit[2]-unit[0])
    target = max(CORNERS,key=lambda name:np.dot(normal,np.cross(
        np.array(CORNERS[name][1])-CORNERS[name][0],
        np.array(CORNERS[name][2])-CORNERS[name][0])))
    order = [int(np.argmin(np.linalg.norm(np.array(CORNERS[target])-point,axis=1))) for point in unit]
    matrix = np.linalg.solve(np.column_stack((corners[:3],np.ones(3))),corners[order][:3])
    return np.column_stack((uv,np.ones(len(uv)))) @ matrix


def texture_name(model, reference):
    """Resolve inherited texture variables and reject cycles or missing names."""
    seen = set()
    while reference.startswith('#'):
        key = reference[1:]
        if key in seen or key not in model.get('textures', {}):
            raise ValueError('Unresolved model texture: ' + reference)
        seen.add(key)
        reference = model['textures'][key]
    return reference if ':' in reference else 'minecraft:' + reference


def application_groups(assets, block, properties):
    """Keep independent multipart groups and weighted choices separate."""
    definition = assets.read('blockstates', block)
    groups = [value for key,value in definition.get('variants', {}).items()
              if selector_matches(parse_variant(key), properties)]
    groups.extend(part['apply'] for part in definition.get('multipart', [])
                  if selector_matches(part.get('when', {}), properties))
    return [choice if isinstance(choice, list) else [choice] for choice in groups]


def model_faces(assets, application):
    """Transform resource quads, preserving thin planes and layered surfaces.

    UV lock follows the engine's cardinal face transform. Runtime capture
    supplies the current atlas placement and observed surface mapping.
    """
    model = assets.model(application['model'])
    transform = rotation(1, -application.get('y', 0)) @ rotation(0, -application.get('x', 0))
    result = []
    for element in model.get('elements', []):
        low = np.array(element['from'], float) / 16
        high = np.array(element['to'], float) / 16
        descriptor = element.get('rotation', {})
        angle = descriptor.get('angle', 0)
        for face, definition in element.get('faces', {}).items():
            points = low + np.array(CORNERS[face]) * (high - low)
            if angle:
                axis = 'xyz'.index(descriptor['axis'])
                pivot = np.array(descriptor['origin'], float) / 16
                points -= pivot
                if descriptor.get('rescale', False):
                    for component in range(3):
                        if component != axis:
                            points[:,component] /= np.cos(np.deg2rad(angle))
                points = points @ rotation(axis, angle).T + pivot
            points = (points - .5) @ transform.T + .5
            normal = np.cross(points[1] - points[0], points[2] - points[0])
            length = np.linalg.norm(normal)
            if length < 1e-10:
                continue
            rectangle = np.array(definition['uv'],float)/16 if 'uv' in definition else default_uv(
                element['from'], element['to'], face)
            logical_uv = face_uv(rectangle, definition.get('rotation', 0))
            if application.get('uvlock', False):
                logical_uv = locked_uv(logical_uv,face,transform)
            result.append({
                'positions': np.round(points, 7).tolist(),
                'normal': np.round(normal / length, 7).tolist(),
                'texture': texture_name(model, definition['texture']),
                'tint': definition.get('tintindex', -1),
                'shade': element.get('shade', True),
                'uv': logical_uv.tolist(),
                'uvlock': application.get('uvlock', False),
                'source_face': face,
                '_cullable': 'cullface' in definition,
            })
    return result


def build(catalog, assets):
    """Intern faces and choices while preserving the state-to-choice relation."""
    quads = []
    quad_ids = {}
    applications = []
    application_cullable = []
    application_ids = {}
    groups = []
    group_ids = {}
    state_groups = []
    for state in catalog['states']:
        selected_groups = []
        for choices in application_groups(assets, state['block'], state['properties']):
            candidates = []
            for application in choices:
                key = json.dumps({name:value for name,value in application.items() if name != 'weight'}, sort_keys=True)
                if key not in application_ids:
                    faces = []
                    cullable = []
                    for face in model_faces(assets, application):
                        cullable.append(face.pop('_cullable'))
                        face_key = json.dumps(face, sort_keys=True)
                        if face_key not in quad_ids:
                            quad_ids[face_key] = len(quads)
                            quads.append(face)
                        faces.append(quad_ids[face_key])
                    application_ids[key] = len(applications)
                    applications.append(faces)
                    application_cullable.append(cullable)
                candidates.append(application_ids[key])
            group_key = tuple(candidates)
            if group_key not in group_ids:
                group_ids[group_key] = len(groups)
                groups.append(candidates)
            selected_groups.append(group_ids[group_key])
        state_groups.append(selected_groups)
    return {'schema_version':1, 'quads':quads, 'applications':applications,
            'application_cullable':application_cullable,
            'groups':groups, 'state_groups':state_groups,
            'scope':'Immutable candidate faces; actual choice and atlas mapping require GPU observations'}


def append_resource(records, surfaces, choices, offsets):
    """Serialize shared faces, predicates, choice profiles and exact offset LUTs."""
    offset_profiles, state_offsets = offsets
    state_count = len(choices['states']) + 1
    states_start = SURFACE_START + 3
    quads_start = states_start + state_count
    references_start = quads_start + len(surfaces['quads']) * 4
    references = []
    sequences = {}
    maximum_faces = 0
    for state, selection in enumerate(choices['states'], 1):
        sequence = tuple(tuple(row) for row in selection['references'])
        if sequence not in sequences:
            sequences[sequence] = len(references)
            references.extend(sequence)
        maximum_faces = max(maximum_faces,len(sequence))
        records[states_start+state] = (sequences[sequence],len(sequence),selection['profile'],state_offsets[state])
    profiles_start = references_start + (len(references) + 1) // 2
    groups_start = profiles_start + len(choices['profiles'])
    group_count = sum(len(profile) for profile in choices['profiles'])
    offsets_start = groups_start + group_count * 3
    end = offsets_start + len(offset_profiles) * 13
    if end >= len(records)-1:
        raise ValueError(f'Model resource needs {end+1} texels; available {len(records)}')
    if maximum_faces > 512 or len(surfaces['quads']) >= 65535:
        raise ValueError('Model faces exceed traversal or packed reference capacity')
    textures = {name:index for index,name in enumerate(sorted({quad['texture'] for quad in surfaces['quads']}))}
    for index,quad in enumerate(surfaces['quads']):
        first = quads_start + index * 4
        points = np.array(quad['positions'])
        normal = np.array(quad['normal'])
        axis = int(np.argmax(abs(normal) - np.arange(3) * .0001))
        face = axis * 2 + int(normal[axis] < 0)
        tint = quad['tint'] + 1
        if not 0 <= tint < 16:
            raise ValueError('Tint index exceeds face identity field')
        records[first:first+3,:3] = points[:3]
        records[first,3] = textures[quad['texture']] * 256 + tint * 16 + int(quad['shade']) * 8 + face
        projected = np.delete(points[:3],axis,axis=1)
        matrix = np.column_stack((projected,np.ones(3)))
        affine = np.linalg.solve(matrix,np.array(quad['uv'])[:3])
        records[first+1,3] = affine[2,0]
        records[first+2,3] = affine[2,1]
        records[first+3] = (*affine[:2,0],*affine[:2,1])
    for index,(face,condition,hint) in enumerate(references):
        if not 0 <= hint < 256 or not -1 <= condition < (1 << 24):
            raise ValueError('Model predicate exceeds exact float integer capacity')
        component = (index % 2) * 2
        records[references_start+index//2,component:component+2] = (face*256+hint,condition)
    next_group = groups_start
    for index,profile in enumerate(choices['profiles']):
        combinations = 1
        for row in profile:
            combinations *= row['count']
        records[profiles_start+index] = (next_group,len(profile),combinations,sum(row['count'] for row in profile))
        for row in profile:
            records[next_group] = (row['count'],row['channel']+row['choice_bit']*4+int(row.get('constraints',False))*1024,row['shift'],row['sum_bits'])
            records[next_group+1] = (row['square_bits'],row['count_bits'],row['maximum_samples'],row['radix_multiplier'])
            records[next_group+2] = (row['coverage_shift'],row['coverage_bits'],row['maximum_coverage'],row['fallback']+1)
            next_group += 3
    # Joint runtime pose is stored in 17 bits alongside exact RGB tint.
    for state,selection in enumerate(choices['states'], 1):
        profile = choices['profiles'][selection['profile']]
        combinations = math.prod(row['count'] for row in profile)
        offsets = math.prod(map(len,offset_profiles[state_offsets[state]]))
        if combinations * offsets > 131072:
            raise ValueError('Joint model/offset pose exceeds persistent field capacity')
    for index,profile in enumerate(offset_profiles):
        first = offsets_start + index * 13
        records[first,:3] = [len(values) for values in profile]
        for axis,values in enumerate(profile):
            for slot,value in enumerate(values):
                records[first+1+axis*4+slot//4,slot%4] = value
    records[SURFACE_START] = (states_start,quads_start,references_start,len(surfaces['quads']))
    records[SURFACE_START+1] = (profiles_start,offsets_start,len(choices['profiles']),len(offset_profiles))
    records[SURFACE_START+2] = (804,2,13,3)
    if len(textures) > 196608-180000:
        raise ValueError('Texture observations exceed the reserved UV cache')
    return {'schema_version':2,'start':SURFACE_START,'end':end,'quad_stride':4,
            'reference_stride':2,'state_table_count':state_count,'quads':len(surfaces['quads']),
            'textures':len(textures),'references':len(references),'state_sequences':len(sequences),
            'max_state_faces':maximum_faces,'choice_profiles':len(choices['profiles']),
            'choice_groups':group_count,'offset_profiles':len(offset_profiles)}


def main():
    folder = ROOT / 'local-docs/migration/runs/P04-model-faces'
    folder.mkdir(parents=True, exist_ok=True)
    catalog = json.loads((ROOT / 'local-docs/migration/prototypes/P04-uv/shaders/world-definitions.json').read_text())
    result = build(catalog, Assets())
    (folder / 'surfaces.json').write_text(json.dumps(result, separators=(',', ':')) + '\n')
    print(json.dumps({key:len(result[key]) for key in ('quads','applications','groups','state_groups')}, indent=2))


if __name__ == '__main__':
    main()
