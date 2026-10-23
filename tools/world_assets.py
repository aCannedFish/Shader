"""Resolve installed vanilla block models into static state/shape descriptors.

Only immutable resource definitions are consumed. This module never reads a
world or extracts live geometry, lighting or caches from a companion Mod.
"""
import itertools
import json
from pathlib import Path
from zipfile import ZipFile

import numpy as np

DEFAULT_JAR = Path('/Users/yuguanting/minecraft/versions/1.21.11-Forge-OptiFine/1.21.11-Forge-OptiFine.jar')


def selector_matches(selector, state):
    if 'OR' in selector:
        return any(selector_matches(child, state) for child in selector['OR'])
    if 'AND' in selector:
        return all(selector_matches(child, state) for child in selector['AND'])
    return all(state.get(key) in str(value).split('|') for key, value in selector.items())


def parse_variant(text):
    return dict(part.split('=', 1) for part in text.split(',') if part)


def rotation(axis, angle):
    result = np.eye(3)
    first, second = ((1,2),(2,0),(0,1))[axis]
    c, s = np.cos(np.deg2rad(angle)), np.sin(np.deg2rad(angle))
    result[first,first] = result[second,second] = c
    result[first,second] = -s
    result[second,first] = s
    return result


class Assets:
    """Model inheritance and block-state selectors follow resource-pack rules."""
    def __init__(self, jar=DEFAULT_JAR, overlays=()):
        self.archives = [ZipFile(jar), *(ZipFile(file) for file in overlays)]
        self.models = {}
        self.names = [set(archive.namelist()) for archive in self.archives]
        self.documents = {}
        self.geometry_parts = {}

    def read(self, kind, identifier):
        namespace, _, name = identifier.partition(':')
        if not name:
            namespace, name = 'minecraft', namespace
        filename = f'assets/{namespace}/{kind}/{name}.json'
        if filename in self.documents:
            return self.documents[filename]
        for archive,names in reversed(list(zip(self.archives,self.names))):
            if filename in names:
                self.documents[filename] = json.loads(archive.read(filename))
                return self.documents[filename]
        raise FileNotFoundError(filename)

    def model(self, identifier):
        if identifier not in self.models:
            child = self.read('models', identifier)
            parent = child.get('parent')
            inherited = self.model(parent) if parent and not parent.startswith('builtin/') else {}
            result = {**inherited, **child}
            result['textures'] = {**inherited.get('textures', {}), **child.get('textures', {})}
            self.models[identifier] = result
        return self.models[identifier]

    def states(self, block):
        definition = self.read('blockstates', block)
        if 'variants' in definition:
            return [parse_variant(key) for key in sorted(definition['variants'])]
        values = {}

        def collect(selector):
            for key, value in selector.items():
                if key in ('OR', 'AND'):
                    for child in value:
                        collect(child)
                else:
                    values.setdefault(key, set()).update(str(value).split('|'))
        for part in definition.get('multipart', []):
            collect(part.get('when', {}))
        for choices in values.values():
            if choices <= {'true', 'false'}:
                choices.update(('true', 'false'))
            if choices <= {'none', 'low', 'tall'}:
                choices.add('none')
        keys = sorted(values)
        return [dict(zip(keys, row)) for row in itertools.product(*(sorted(values[key]) for key in keys))]

    def applications(self, block, state):
        definition = self.read('blockstates', block)
        choices = []
        for key, value in definition.get('variants', {}).items():
            if selector_matches(parse_variant(key), state):
                choices.append(value)
        for part in definition.get('multipart', []):
            if selector_matches(part.get('when', {}), state):
                choices.append(part['apply'])
        # Weighted variants can have distinct UV rotations. The shape contract
        # preserves every candidate; runtime observation chooses surface details.
        return [application for choice in choices
                for application in (choice if isinstance(choice, list) else [choice])]

    def oriented_application(self, application):
        """Resolve one candidate model, retaining planes and element rotations."""
        key = (application['model'], application.get('x',0), application.get('y',0))
        if key in self.geometry_parts:
            return self.geometry_parts[key]
        parts = set()
        angles = {0.0:0, 22.5:1, -22.5:2, 45.0:3, -45.0:4}
        model = self.model(application['model'])
        transform = rotation(1,-application.get('y',0)) @ rotation(0,-application.get('x',0))
        for element in model.get('elements',[]):
            low = np.array(element['from'],float)/16
            high = np.array(element['to'],float)/16
            if np.count_nonzero(high>low)<2:
                continue
            corners = np.array(list(itertools.product(*zip(low,high))))
            corners = (corners-.5) @ transform.T + .5
            lower = np.round(corners.min(axis=0),7)
            upper = np.round(corners.max(axis=0),7)
            descriptor = element.get('rotation',{})
            angle = float(descriptor.get('angle',0))
            pivot = np.zeros(3)
            code = 0
            if angle:
                basis = np.eye(3)['xyz'.index(descriptor['axis'])]
                transformed_axis = transform @ basis
                axis = int(np.argmax(abs(transformed_axis)))
                angle *= float(round(transformed_axis[axis]))
                if angle not in angles:
                    raise ValueError('Unsupported model element angle: '+str(angle))
                pivot = np.round(transform @ (np.array(descriptor['origin'],float)/16-.5)+.5,7)
                code = angles[angle]+axis*5+int(descriptor.get('rescale',False))*15
            parts.add(tuple(float(value) for value in np.r_[lower,upper,pivot,code]))
        result = tuple(sorted(parts))
        self.geometry_parts[key] = result
        return result

    def oriented_parts(self, block, state):
        """Keep the candidate union and explicitly report ambiguous choices."""
        return sorted({part for application in self.applications(block,state)
                       for part in self.oriented_application(application)})

    def variation_flags(self, block, state):
        """Separate model geometry ambiguity from UV-only weighted variation."""
        definition = self.read('blockstates',block)
        choices = [value for key,value in definition.get('variants',{}).items()
                   if selector_matches(parse_variant(key),state)]
        choices.extend(part['apply'] for part in definition.get('multipart',[])
                       if selector_matches(part.get('when',{}),state))
        geometry = False
        uv = False
        for choice in choices:
            if isinstance(choice,list) and len(choice)>1:
                geometry |= len({self.oriented_application(item) for item in choice})>1
                uv |= len({json.dumps({key:value for key,value in item.items() if key!='weight'},sort_keys=True)
                           for item in choice})>1
        return geometry,uv

    def boxes(self, block, state):
        boxes = []
        for application in self.applications(block, state):
            model = self.model(application['model'])
            transform = rotation(1, -application.get('y', 0)) @ rotation(0, -application.get('x', 0))
            for element in model.get('elements', []):
                if element.get('rotation', {}).get('angle', 0) % 90:
                    raise ValueError('Oriented element requires OBB descriptor: ' + application['model'])
                lower = np.array(element['from'], float) / 16
                upper = np.array(element['to'], float) / 16
                corners = np.array(list(itertools.product(*zip(lower, upper))))
                corners = (corners - .5) @ transform.T + .5
                low = np.round(corners.min(axis=0), 7)
                high = np.round(corners.max(axis=0), 7)
                if np.all(high > low):
                    boxes.append((tuple(low), tuple(high)))
        return sorted(set(boxes))


def shape_fixture(assets):
    """Representative model families include all rotations and connection states."""
    blocks = ('stone_slab', 'stone_brick_stairs', 'oak_door', 'oak_trapdoor',
              'oak_fence', 'glass_pane', 'oak_fence_gate')
    states = []
    for block in blocks:
        for state in assets.states(block):
            states.append({'block': block, 'properties': state, 'boxes': assets.boxes(block, state)})
    return states
