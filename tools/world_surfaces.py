"""Compile individual immutable model faces without merging coincident layers.

Bounds alone cannot distinguish fence posts, crossbars or grass overlays. These
records retain each quad's position, texture identity, tint and model choice.
Atlas coordinates are learned by the GPU from actual submitted primitives.
"""
import json
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

    UV lock is retained as provenance. Runtime capture supplies the final affine
    atlas mapping, so this compiler does not approximate the loader's UV lock.
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
                # UV lock uses the cardinal model-state transform, independent
                # of an element's own rotation. Match unit-face corner order.
                unit = (np.array(CORNERS[face], float) - .5) @ transform.T + .5
                cardinal = np.cross(unit[1] - unit[0], unit[2] - unit[0])
                target = max(CORNERS, key=lambda name: np.dot(cardinal, np.cross(
                    np.array(CORNERS[name][1]) - CORNERS[name][0],
                    np.array(CORNERS[name][2]) - CORNERS[name][0])))
                order = [int(np.argmin(np.linalg.norm(np.array(CORNERS[target]) - corner, axis=1)))
                         for corner in unit]
                logical_uv = logical_uv[order]
            result.append({
                'positions': np.round(points, 7).tolist(),
                'normal': np.round(normal / length, 7).tolist(),
                'texture': texture_name(model, definition['texture']),
                'tint': definition.get('tintindex', -1),
                'shade': element.get('shade', True),
                'uv': logical_uv.tolist(),
                'uvlock': application.get('uvlock', False),
                'source_face': face,
            })
    return result


def build(catalog, assets):
    """Intern faces and choices while preserving the state-to-choice relation."""
    quads = []
    quad_ids = {}
    applications = []
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
                    for face in model_faces(assets, application):
                        face_key = json.dumps(face, sort_keys=True)
                        if face_key not in quad_ids:
                            quad_ids[face_key] = len(quads)
                            quads.append(face)
                        faces.append(quad_ids[face_key])
                    application_ids[key] = len(applications)
                    applications.append(faces)
                candidates.append(application_ids[key])
            group_key = tuple(candidates)
            if group_key not in group_ids:
                group_ids[group_key] = len(groups)
                groups.append(candidates)
            selected_groups.append(group_ids[group_key])
        state_groups.append(selected_groups)
    return {'schema_version':1, 'quads':quads, 'applications':applications,
            'groups':groups, 'state_groups':state_groups,
            'scope':'Immutable candidate faces; actual choice and atlas mapping require GPU observations'}


def append_resource(records, surfaces):
    """Use the existing static texture's spare area, with checked boundaries.

    RGBA32F references remain exact integers. State lists share identical quad
    sequences; the runtime still distinguishes candidates from observed faces.
    """
    states_start = SURFACE_START + 1
    quads_start = states_start + 32768
    references_start = quads_start + len(surfaces['quads']) * 4
    references = []
    sequences = {}
    for state, groups in enumerate(surfaces['state_groups'], 1):
        ids = tuple(sorted({quad for group in groups for application in surfaces['groups'][group]
                            for quad in surfaces['applications'][application]}))
        if ids not in sequences:
            sequences[ids] = len(references)
            references.extend(ids)
        records[states_start + state] = (sequences[ids], len(ids), 0, 0)
    end = references_start + (len(references) + 3) // 4
    if end >= len(records) - 1:
        raise ValueError(f'Model faces exceed static resource: {end} >= {len(records)-1}')
    textures = {name:index for index,name in enumerate(sorted({quad['texture'] for quad in surfaces['quads']}))}
    for index, quad in enumerate(surfaces['quads']):
        first = quads_start + index * 4
        points = np.array(quad['positions'])
        normal = np.array(quad['normal'])
        axis = int(np.argmax(abs(normal) - np.arange(3) * .0001))
        face = axis * 2 + int(normal[axis] < 0)
        records[first:first+3,:3] = points[:3]
        tint = quad['tint'] + 1
        if not 0 <= tint < 16:
            raise ValueError('Tint index exceeds face identity field')
        records[first,3] = textures[quad['texture']] * 256 + tint * 16 + int(quad['shade']) * 8 + face
        projected = np.delete(points[:3], axis, axis=1)
        matrix = np.column_stack((projected, np.ones(3)))
        affine = np.linalg.solve(matrix, np.array(quad['uv'])[:3])
        records[first+1,3] = affine[2,0]
        records[first+2,3] = affine[2,1]
        records[first+3] = (*affine[:2,0], *affine[:2,1])
    for index, value in enumerate(references):
        records[references_start + index // 4, index % 4] = value
    records[SURFACE_START] = (states_start, quads_start, references_start, len(surfaces['quads']))
    if len(textures) > 196608 - 180000 or len(surfaces['quads']) >= 180000:
        raise ValueError('Model and texture observations overlap in the UV cache')
    return {'start':SURFACE_START, 'end':end, 'quad_stride':4, 'quads':len(surfaces['quads']),
            'textures':len(textures), 'references':len(references), 'state_sequences':len(sequences),
            'max_state_faces':max(int(row[1]) for row in records[states_start:states_start+32768])}


def main():
    folder = ROOT / 'local-docs/migration/runs/P04-model-faces'
    folder.mkdir(parents=True, exist_ok=True)
    catalog = json.loads((ROOT / 'local-docs/migration/prototypes/P04-uv/shaders/world-definitions.json').read_text())
    result = build(catalog, Assets())
    (folder / 'surfaces.json').write_text(json.dumps(result, separators=(',', ':')) + '\n')
    print(json.dumps({key:len(result[key]) for key in ('quads','applications','groups','state_groups')}, indent=2))


if __name__ == '__main__':
    main()
