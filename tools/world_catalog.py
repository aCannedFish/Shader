"""Compile immutable vanilla states into shader-owned definition textures.

Emission levels and render layers come from the matching game registry. Model
bounds come from its resource definitions. Neither source contains live scene
positions, chunk data, light volumes or companion caches.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
from world_assets import Assets
from world_surfaces import build as build_surfaces, append_resource
from world_choices import normalize, compile_choices
from world_offsets import load_profiles
from migration_inputs import load_input

ROOT = Path(__file__).resolve().parents[1]
STATE_CAPACITY = 32768
STATE_STRIDE = 3
SHAPE_STRIDE = 3
SHAPE_CAPACITY = 65536
STATIC_SIZE = (512,1152,1)
SHAPE_START = STATE_CAPACITY * STATE_STRIDE
ENVIRONMENT_START = 140000
ORE_DIRECTORY_START = ENVIRONMENT_START + STATE_CAPACITY
ORE_TEXTURES = (
    'coal_ore', 'deepslate_coal_ore', 'iron_ore', 'deepslate_iron_ore',
    'copper_ore', 'deepslate_copper_ore', 'gold_ore', 'deepslate_gold_ore',
    'redstone_ore', 'deepslate_redstone_ore', 'lapis_ore', 'deepslate_lapis_ore',
    'emerald_ore', 'deepslate_emerald_ore', 'diamond_ore', 'deepslate_diamond_ore',
    'nether_gold_ore', 'nether_quartz_ore',
)
MAX_SHAPE_PARTS = 64

WATERLOGGED = 1
VANILLA_ONLY_LIGHT = 2
TINTED_LIGHT_BLOCKER = 4
ANIMATED_MODEL = 8
MODEL_ALTERNATIVES = 16
THIN_MODEL = 32
AIR = 64
FLUID = 128
FULL_CUBE = 256
EMPTY_MODEL = 512
UV_ALTERNATIVES = 1024
MODEL_OFFSET = 2048

# Display colours preserve the companion's authored hues. The registry supplies
# energy separately; these values must never be added as a second light level.
EMISSION_COLOURS = {
    'torch': (1,.88,.67), 'wall_torch': (1,.88,.67), 'lantern': (1,.88,.67),
    'soul_torch': (.38,.72,1), 'soul_wall_torch': (.38,.72,1),
    'soul_lantern': (.38,.72,1), 'soul_fire': (.38,.72,1), 'soul_campfire': (.38,.72,1),
    'redstone_torch': (1,.12,.05), 'redstone_wall_torch': (1,.12,.05),
    'sea_lantern': (1,1,1), 'beacon': (1,1,1), 'light': (1,1,1),
    'glowstone': (1,.82,.49), 'redstone_lamp': (1,.82,.49),
    'shroomlight': (1,.68,.36), 'jack_o_lantern': (1,.68,.36),
    'fire': (1,.71,.38), 'campfire': (1,.71,.38),
    'lava': (1,.36,.08), 'magma_block': (1,.36,.08), 'end_rod': (1,.96,.86),
    'amethyst_cluster': (.74,.46,1), 'large_amethyst_bud': (.74,.46,1),
    'medium_amethyst_bud': (.74,.46,1), 'small_amethyst_bud': (.74,.46,1),
    'crying_obsidian': (.67,.24,1), 'respawn_anchor': (.67,.24,1),
    'nether_portal': (.65,.15,1), 'ochre_froglight': (1,.92,.59),
    'verdant_froglight': (.70,1,.66), 'pearlescent_froglight': (.94,.72,1),
    'glow_lichen': (.73,.95,.64), 'glow_berries': (.73,.95,.64),
    'cave_vines': (.73,.95,.64), 'cave_vines_plant': (.73,.95,.64),
    'sculk_catalyst': (.20,.65,.85), 'sculk_sensor': (.20,.65,.85),
    'calibrated_sculk_sensor': (.20,.65,.85), 'copper_torch': (.36,1,.65),
    'copper_wall_torch': (.36,1,.65), 'copper_lantern': (.36,1,.65),
    'copper_fire': (.36,1,.65),
}


def legacy_rules(text):
    rules = []
    for line in text.splitlines():
        if not line.startswith('block.') or '=' not in line:
            continue
        key,values = line.split('=',1)
        legacy = int(key.split('.')[1].strip())
        for token in values.split():
            fields = token.split(':')
            conditions = dict(field.split('=',1) for field in fields[2:])
            rules.append((fields[0]+':'+fields[1],conditions,legacy))
    return rules


def legacy_class(name, properties, rules):
    for block,conditions,legacy in rules:
        if block == name and all(properties.get(key) in value.split(',') for key,value in conditions.items()):
            return legacy
    return 0


def emission_colour(name):
    short = name.split(':')[1]
    default = (1,.88,.67) if short.endswith(('_candle','_candle_cake')) or short in ('candle','candle_cake') else (1,.95,.85)
    return np.array(EMISSION_COLOURS.get(short,default),float)**2.2


def glass_absorption(name, dyes):
    """Keep full glass and pane optical thickness distinct, including neutrals."""
    short = name.split(':')[1]
    dye = next((colour for colour in dyes if short in (colour+'_stained_glass',colour+'_stained_glass_pane')),None)
    if short == 'tinted_glass':
        return np.full(3,-np.log(.18))
    if dye is None:
        return np.zeros(3)
    packed = dyes[dye]
    colour = np.array([(packed>>16)&255,(packed>>8)&255,packed&255],float)/255
    peak = max(float(colour.max()),.001)
    transmission = (.35+.60*peak)*(.12+.88*(colour/peak)**1.5)
    neutral = {'white':.94,'light_gray':.80,'gray':.60,'black':.28}
    if dye in neutral:
        transmission[:] = neutral[dye]
    thickness = .125 if short.endswith('_pane') else 1.0
    return -np.log(transmission)/thickness


def make_catalog(definitions, assets, rules):
    """Assign one exact alias per registry state; no property is silently lost."""
    states = []
    shapes = []
    shape_offsets = {}
    defaults = {}
    for block in definitions['blocks']:
        name = block['name']
        for state in block['states']:
            properties = state['properties']
            parts = tuple(assets.oriented_parts(name,properties))
            fluid = name in ('minecraft:water','minecraft:lava')
            if fluid:
                level = int(properties['level'])
                height = 8/9 if level == 0 or level>=8 else (8-level)/9
                parts = ((0.,0.,0.,1.,height,1.,0.,0.,0.,0.),)
            if len(parts)>MAX_SHAPE_PARTS:
                raise ValueError(f'{name} exceeds the per-state shape budget: {len(parts)}')
            if parts not in shape_offsets:
                shape_offsets[parts] = len(shapes)
                shapes.extend(parts)
            flags = 0
            # Immutable source anchors replace the companion's per-light upload.
            # Bits 12..14 fit the existing split high-flags field exactly.
            if name in ('minecraft:wall_torch','minecraft:soul_wall_torch',
                        'minecraft:redstone_wall_torch','minecraft:copper_wall_torch'):
                direction = ('north','south','west','east').index(properties['facing'])
                flags |= 4096 | (direction << 13)
            if name == 'minecraft:conduit':
                flags |= 8192
            if name == 'minecraft:beacon':
                flags |= 16384
            if name == 'minecraft:ender_chest':
                flags |= 65536
            if name in ('minecraft:end_portal','minecraft:end_gateway'):
                flags |= 32768
            if state.get('has_model_offset',False):
                flags |= MODEL_OFFSET
            if properties.get('waterlogged') == 'true':
                flags |= WATERLOGGED
            if name == 'minecraft:light':
                flags |= VANILLA_ONLY_LIGHT
            if name == 'minecraft:tinted_glass':
                flags |= TINTED_LIGHT_BLOCKER
            if state.get('rendered_block_entity',False) or state['render_shape'] == 'ENTITYBLOCK_ANIMATED':
                flags |= ANIMATED_MODEL
            if any(part[axis] == part[axis+3] for part in parts for axis in range(3)):
                flags |= THIN_MODEL
            if state['air']:
                flags |= AIR
            if fluid:
                flags |= FLUID
            if not parts:
                flags |= EMPTY_MODEL
            geometry_variation,uv_variation = assets.variation_flags(name,properties)
            if geometry_variation:
                flags |= MODEL_ALTERNATIVES
            if uv_variation:
                flags |= UV_ALTERNATIVES
            alpha = 3 if fluid else 2 if state['render_layer'] == 'TRANSLUCENT' else 1 if state['render_layer'].startswith('CUTOUT') else 0
            if len(parts)==1 and parts[0][:6] == (0.,0.,0.,1.,1.,1.) and parts[0][-1]==0 and alpha==0:
                flags |= FULL_CUBE
            alias = len(states)+1
            if alias>=STATE_CAPACITY:
                raise ValueError('State aliases exceed signed shader input capacity')
            definition = {'id':alias,'block':name,'properties':properties,'first_box':shape_offsets[parts],
                          'box_count':len(parts),'legacy':legacy_class(name,properties,rules),
                          'emission':state['emission'],
                          'emission_rgb':emission_colour(name).tolist() if state['emission']>0 else [0.,0.,0.],
                          'absorption':glass_absorption(name,definitions['dye_texture_colours']).tolist(),
                          'alpha':alpha,'flags':flags,'render_layer':state['render_layer'],
                          'render_shape':state['render_shape'],
                          'rendered_block_entity':state.get('rendered_block_entity',False)}
            states.append(definition)
            if properties==block['defaults']: defaults[name]=alias
    if len(shapes)>SHAPE_CAPACITY:
        raise ValueError('Shape records exceed the allocated table')
    return states,shapes,defaults,len(shape_offsets)


def encode(states, shapes):
    records = np.zeros((np.prod(STATIC_SIZE),4),'<f4')
    if SHAPE_START + len(shapes) * SHAPE_STRIDE > ENVIRONMENT_START:
        raise ValueError('Shape data overlaps the immutable environment descriptors')
    for state in states:
        index = state['id']*STATE_STRIDE
        first = state['first_box']
        records[index] = (first%2048,first//2048+(state['flags']>>11)*32,state['box_count'],state['legacy'])
        records[index+1,:3] = state['emission_rgb']
        records[index+1,3] = state['emission']+state['alpha']*16
        records[index+2,:3] = state['absorption']
        records[index+2,3] = state['flags']&2047
        name = state['block'].split(':',1)[1]
        tree = name.endswith(('_leaves','_log','_wood','_stem','_hyphae'))
        analytical = False
        parts = shapes[first:first+state['box_count']]
        if state['emission'] > 0 and parts and not state['flags'] & (ANIMATED_MODEL | FLUID):
            low = np.min(np.array([part[:3] for part in parts]), axis=0)
            high = np.max(np.array([part[3:6] for part in parts]), axis=0)
            extent = sorted(high - low)
            analytical = extent[2] <= 0.75 or (extent[1] <= 0.25 and extent[2] <= 1.0)
        records[ENVIRONMENT_START+state['id']] = (float(tree),
            float(bool(state['flags'] & WATERLOGGED)), float(analytical), 631.0)
    for index,part in enumerate(shapes):
        start = SHAPE_START+index*SHAPE_STRIDE
        records[start,:3] = part[:3]
        records[start+1,:3] = part[3:6]
        records[start+2] = part[6:]
    records[-1] = list(hashlib.sha256(records.tobytes()).digest()[:4])
    return records


def build(target, definitions_file=None):
    definitions = load_input('vanilla-blocks', definitions_file)
    assets = Assets()
    states,shapes,defaults,unique = make_catalog(definitions,assets,legacy_rules((ROOT/'shaders/block.properties').read_text()))
    target.mkdir(parents=True,exist_ok=True)
    texture = target/'textures/world-static.bin'
    texture.parent.mkdir(parents=True,exist_ok=True)
    records = encode(states,shapes)
    surfaces, _ = normalize(build_surfaces({'states':states}, assets))
    choices = compile_choices(surfaces)
    if choices['unresolved_choices']:
        raise ValueError('Model choices lack a verified observation rule')
    surface_contract = append_resource(records, surfaces, choices, load_profiles(states))
    texture_ids = {name:index for index,name in enumerate(sorted({quad['texture'] for quad in surfaces['quads']}))}
    for index,name in enumerate(ORE_TEXTURES):
        host = 2 if index >= 16 else index % 2
        records[ORE_DIRECTORY_START+index] = (texture_ids['minecraft:block/'+name],host,0,917)
    (target/'world-choices.json').write_text(json.dumps(choices,separators=(',', ':'))+'\n')
    records[-1] = 0
    records[-1] = list(hashlib.sha256(records.tobytes()).digest()[:4])
    texture.write_bytes(records.tobytes())
    (target/'world-surfaces.json').write_text(json.dumps(surfaces, separators=(',', ':'))+'\n')
    aliases = ['# Generated from immutable vanilla states; state zero is unknown.']
    for state in states:
        selector = state['block']+''.join(':'+key+'='+value for key,value in sorted(state['properties'].items()))
        aliases.append(f"block.{state['id']} = {selector}")
    (target/'block.properties').write_text('\n'.join(aliases)+'\n')
    catalog = {'schema_version':2,'state_stride':STATE_STRIDE,'shape_stride':SHAPE_STRIDE,
               'static_size':STATIC_SIZE,'shape_start':SHAPE_START,'state_capacity':STATE_CAPACITY,
               'shape_capacity':SHAPE_CAPACITY,'max_shape_parts':MAX_SHAPE_PARTS,
               'unique_shapes':unique,'shape_parts':len(shapes),'states':states,'defaults':defaults,
               'surface_contract':surface_contract}
    (target/'world-definitions.json').write_text(json.dumps(catalog,indent=2)+'\n')
    (target/'world-default-aliases.json').write_text(json.dumps(defaults,indent=2)+'\n')
    return catalog


if __name__=='__main__':
    target=ROOT/'local-docs/migration/prototypes/P04/shaders'
    result=build(target)
    print(f"Encoded {len(result['states'])} exact states, {result['unique_shapes']} shapes and {result['shape_parts']} parts")
