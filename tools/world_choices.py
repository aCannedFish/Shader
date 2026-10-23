"""Compile observable model choices and exact additive packing budgets.

These are immutable resource relationships. No live block positions or selected
choices are read. The GPU must still discover the choices from submitted faces.
"""
from collections import defaultdict
import json
import hashlib
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def canonical_face(face):
    """Keep winding and position-to-UV correspondence while fixing corner order."""
    result = dict(face)
    # Rotation can produce -0.0. JSON distinguishes its spelling from 0.0,
    # while the GPU cannot; normalize it before deriving unique witnesses.
    for key in ('positions','normal','uv'):
        values = np.asarray(face[key],dtype=float)
        result[key] = np.where(values == 0.0,0.0,values).tolist()
    points = np.array(result['positions'])
    uv = np.array(result['uv'])
    first = min(range(4), key=lambda index: tuple(points[index]))
    result['positions'] = np.roll(points, -first, axis=0).tolist()
    result['uv'] = np.roll(uv, -first, axis=0).tolist()
    return result


def face_identity(face):
    return json.dumps({key:value for key,value in face.items() if key not in ('source_face','uvlock')},
                      sort_keys=True, separators=(',', ':'))


def normalize(surfaces):
    """Intern identical physical faces without removing repeated layer references."""
    quads = []
    identities = {}
    remap = []
    for source in surfaces['quads']:
        face = canonical_face(source)
        key = face_identity(face)
        if key not in identities:
            identities[key] = len(quads)
            quads.append(face)
        remap.append(identities[key])
    result = dict(surfaces)
    result['quads'] = quads
    result['applications'] = [[remap[index] for index in application] for application in surfaces['applications']]
    return result, remap


def application_identity(quads, application, cullable):
    """Ignore separate-face ordering and preserve coincident layer/cull rules."""
    layers = defaultdict(list)
    for index, culled in zip(application, cullable):
        quad = quads[index]
        geometry = json.dumps([quad['positions'],quad['normal']], separators=(',', ':'))
        layers[geometry].append((index, culled))
    return tuple(sorted((key,tuple(value)) for key,value in layers.items()))


def pack_groups(choices, witnesses, coverage, fallback, constraints):
    """Pack count, first/second moments and coverage into exact float integers."""
    occupied = [0] * 3
    profile = []
    multiplier = 1
    first_bit = 0
    coverage_shift = 0
    for group, candidates in enumerate(choices):
        count = len(candidates)
        if constraints[group]:
            maximum_samples = max(map(len,candidates))
            vote_bits = maximum_samples.bit_length()
            if count > 16 or 24 % vote_bits:
                raise ValueError('Unsupported exclusion-vote field width')
            channels = math.ceil(count * vote_bits / 24)
            starts = [first for first in range(4-channels)
                      if all(occupied[index] == 0 for index in range(first,first+channels))]
            if not starts:
                raise ValueError('Model exclusion votes exceed additive channels')
            channel = starts[0]
            for index in range(channel,channel+channels):
                occupied[index] = 24
            coverage_bits = maximum_samples.bit_length()
            profile.append({'count':count,'maximum_samples':maximum_samples,
                'sum_bits':vote_bits,'square_bits':0,'count_bits':0,'channel':channel,
                'shift':0,'bits':channels*24,'choice_bit':first_bit,'radix_multiplier':multiplier,
                'coverage_shift':coverage_shift,'coverage_bits':coverage_bits,
                'maximum_coverage':maximum_samples,'fallback':-1,'constraints':True})
            coverage_shift += coverage_bits
            multiplier *= count
            first_bit += count
            continue
        maximum_samples = max(sum(face in selected for face in application)
                              for application,selected in zip(candidates,witnesses[group]))
        maximum_samples = max(maximum_samples,1)
        sum_bits = (maximum_samples * count).bit_length()
        square_bits = (maximum_samples * count * count).bit_length()
        count_bits = maximum_samples.bit_length()
        # One unused high bit catches a count carry before it can leak into
        # the following group's field or masquerade as a missing observation.
        bits = sum_bits + square_bits + count_bits + 1
        possible = [channel for channel in range(3) if occupied[channel] + bits <= 24]
        if not possible:
            raise ValueError('Model choice moments exceed three exact additive channels')
        channel = min(possible, key=lambda index: occupied[index])
        maximum_coverage = max(application.count(coverage[group]) for application in candidates)
        coverage_bits = maximum_coverage.bit_length()
        profile.append({'count':count, 'maximum_samples':maximum_samples,
                        'sum_bits':sum_bits, 'square_bits':square_bits, 'count_bits':count_bits,
                        'channel':channel, 'shift':occupied[channel], 'bits':bits,
                        'choice_bit':first_bit, 'radix_multiplier':multiplier,
                        'coverage_shift':coverage_shift, 'coverage_bits':coverage_bits,
                        'maximum_coverage':maximum_coverage, 'fallback':fallback[group]})
        occupied[channel] += bits
        multiplier *= count
        first_bit += count
        coverage_shift += coverage_bits
    if first_bit > 30 or multiplier >= 2048 or coverage_shift > 24:
        raise ValueError('Model choices exceed mask, half-float identity or coverage capacity')
    return profile


def compile_choices(surfaces):
    """Use unique witnesses, and prove a fallback only with uncullable coverage."""
    profiles = []
    profile_ids = {}
    states = []
    unresolved_choices = 0
    fallback_groups = 0
    signatures = [application_identity(surfaces['quads'],faces,cullable)
                  for faces,cullable in zip(surfaces['applications'],surfaces['application_cullable'])]
    for selected in surfaces['state_groups']:
        fixed = set()
        variable = []
        variable_indices = []
        variable_unculled = []
        for group in selected:
            candidates = []
            indices = []
            unculled = []
            seen = set()
            for application_index in surfaces['groups'][group]:
                application = surfaces['applications'][application_index]
                signature = signatures[application_index]
                if signature not in seen:
                    seen.add(signature)
                    candidates.append(application)
                    indices.append(application_index)
                    unculled.append({face for face,cullable in zip(application,
                        surfaces['application_cullable'][application_index]) if not cullable})
            if len(candidates) <= 1:
                if candidates:
                    fixed.update(candidates[0])
            else:
                variable.append(candidates)
                variable_indices.append(indices)
                variable_unculled.append(unculled)
        conditions = {}
        first_bit = 0
        for candidates in variable:
            for choice, faces in enumerate(candidates):
                for face in faces:
                    conditions[face] = conditions.get(face,0) | (1 << (first_bit+choice))
            first_bit += len(candidates)
        for face in fixed:
            conditions[face] = -1
        hints = {}
        witnesses = []
        coverage = []
        fallback = []
        constraints = []
        first_bit = 0
        for group,candidates in enumerate(variable):
            group_mask = ((1 << len(candidates))-1) << first_bit
            exclusive = {face for face,mask in conditions.items() if mask > 0 and mask & ~group_mask == 0}
            selected_witnesses = []
            for choice,faces in enumerate(candidates):
                unique = {face for face in faces if conditions[face] == 1 << (first_bit+choice)}
                guaranteed = unique & variable_unculled[group][choice]
                witness = {min(guaranteed)} if guaranteed else unique
                selected_witnesses.append(witness)
                for face in witness:
                    hints[face] = (group+1)*16+choice
            common = set.intersection(*variable_unculled[group]) & exclusive
            coverage_face = min(common) if common else -1
            missing = [index for index,witness in enumerate(selected_witnesses) if not witness]
            fallback_choice = -1
            if len(missing) == 1 and coverage_face >= 0:
                alternatives_guaranteed = all(bool(witness & variable_unculled[group][index])
                                              for index,witness in enumerate(selected_witnesses) if witness)
                if alternatives_guaranteed:
                    fallback_choice = missing[0]
                    hints[coverage_face] = 128+group
                    fallback_groups += 1
            # Some UV variants (netherrack's sixteen rotations) have no single
            # unique face. Observe their compatible candidate sets jointly.
            # Equal-size distinct face sets can be resolved by exclusion votes;
            # partial visibility remains explicitly unresolved on the GPU.
            sets = [set(faces) for faces in candidates]
            constrain = len(missing) > int(fallback_choice >= 0) and all(
                not (a <= b) for i,a in enumerate(sets) for j,b in enumerate(sets) if i != j)
            constraints.append(constrain)
            if constrain:
                for face in set.union(*sets):
                    hints[face] = 192+group
            else:
                unresolved_choices += len(missing) - int(fallback_choice >= 0)
            witnesses.append(selected_witnesses)
            coverage.append(coverage_face if fallback_choice >= 0 else -1)
            fallback.append(fallback_choice)
            first_bit += len(candidates)
        profile = pack_groups(variable,witnesses,coverage,fallback,constraints)
        profile_key = json.dumps(profile, sort_keys=True)
        if profile_key not in profile_ids:
            profile_ids[profile_key] = len(profiles)
            profiles.append(profile)
        # Preserve the order of coincident layers, including a dirt base and
        # grass overlay. Global face IDs alone do not define compositing order.
        predecessors = {face:set() for face in conditions}
        for group in selected:
            for application in surfaces['groups'][group]:
                layers = defaultdict(list)
                for face in surfaces['applications'][application]:
                    quad = surfaces['quads'][face]
                    geometry = json.dumps([quad['positions'],quad['normal']],separators=(',', ':'))
                    layers[geometry].append(face)
                for stack in layers.values():
                    for lower,upper in zip(stack,stack[1:]):
                        if lower != upper:
                            predecessors[upper].add(lower)
        ordered = []
        pending = set(conditions)
        while pending:
            ready = sorted(face for face in pending if not predecessors[face] & pending)
            if not ready:
                raise ValueError('Conflicting coincident material layer order')
            ordered.extend(ready)
            pending.difference_update(ready)
        references = [[face,conditions[face],hints.get(face,0)] for face in ordered]
        states.append({'profile':profile_ids[profile_key], 'references':references,
                       'groups':variable_indices})
    return {'profiles':profiles, 'states':states, 'unresolved_choices':unresolved_choices,
            'fallback_group_instances':fallback_groups}


def main():
    source = ROOT/'local-docs/migration/checkpoints/P04.2-raw/verified-native-pack/world-surfaces.json'
    output = ROOT/'local-docs/migration/runs/P04-choice-audit-v3'
    output.mkdir(parents=True, exist_ok=True)
    from world_surfaces import build as build_surfaces
    from world_assets import Assets, DEFAULT_JAR
    catalog = json.loads((source.parent/'world-definitions.json').read_text())
    original = build_surfaces(catalog,Assets())
    surfaces, remap = normalize(original)
    choices = compile_choices(surfaces)
    (output/'surfaces.json').write_text(json.dumps(surfaces,separators=(',', ':'))+'\n')
    (output/'choices.json').write_text(json.dumps(choices,separators=(',', ':'))+'\n')
    profiles = choices['profiles']
    report = {'passed':choices['unresolved_choices'] == 0,
              'source_faces':len(original['quads']), 'canonical_faces':len(surfaces['quads']),
              'states':len(choices['states']), 'profiles':len(profiles),
              'maximum_independent_groups':max(map(len,profiles)),
              'maximum_mask_bits':max(sum(row['count'] for row in profile) for profile in profiles),
              'maximum_combinations':max(math.prod(row['count'] for row in profile) for profile in profiles),
              'unresolved_choice_instances':choices['unresolved_choices'],
              'proven_fallback_group_instances':choices['fallback_group_instances'],
              'resource_jar_sha256':hashlib.sha256(DEFAULT_JAR.read_bytes()).hexdigest(),
              'state_catalog_sha256':hashlib.sha256((source.parent/'world-definitions.json').read_bytes()).hexdigest(),
              'scope':'Static witness/coverage proof and bounded moment packing; native discovery remains unimplemented'}
    (output/'audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
