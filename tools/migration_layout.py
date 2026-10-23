#!/usr/bin/env python3
"""Deterministic atlas layout and allocation ledger for the complete migration.

The layout is a resource contract, not evidence that its consumers are implemented.
RGBA16F integer fields are limited to 0..2047; large identifiers and UV origins
must use split fields. No runtime structure stores absolute world coordinates.
"""
import argparse
from dataclasses import dataclass
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Region:
    name: str
    width: int
    height: int
    purpose: str


def contains(a, b):
    return a[0] <= b[0] and a[1] <= b[1] and a[0]+a[2] >= b[0]+b[2] and a[1]+a[3] >= b[1]+b[3]


def pack(regions, width, height):
    """MaxRects with stable ordering; regions retain their canonical orientation."""
    free = [(0, 0, width, height)]
    placements = {}
    for region in sorted(regions, key=lambda r: (-r.width*r.height, -r.height, r.name)):
        rw, rh = region.width+2, region.height+2
        candidates = [(min(w-rw,h-rh), max(w-rw,h-rh), y, x, index)
                      for index,(x,y,w,h) in enumerate(free) if w >= rw and h >= rh]
        if not candidates:
            return None
        _,_,y,x,_ = min(candidates)
        used = (x,y,rw,rh)
        split = []
        for fx,fy,fw,fh in free:
            if x >= fx+fw or x+rw <= fx or y >= fy+fh or y+rh <= fy:
                split.append((fx,fy,fw,fh))
                continue
            if x > fx: split.append((fx,fy,x-fx,fh))
            if x+rw < fx+fw: split.append((x+rw,fy,fx+fw-x-rw,fh))
            if y > fy: split.append((fx,fy,fw,y-fy))
            if y+rh < fy+fh: split.append((fx,y+rh,fw,fy+fh-y-rh))
        unique = sorted(set(split))
        free = [r for i,r in enumerate(unique) if not any(i != j and contains(other,r) for j,other in enumerate(unique))]
        placements[region.name] = {'x':x+1,'y':y+1,'width':region.width,'height':region.height,
                                   'purpose':region.purpose,'allocation':[x,y,rw,rh]}
    return placements


def atlas(regions, maximum, square=False):
    minimum = sum((r.width+2)*(r.height+2) for r in regions)
    # Float atlases need no mip chain. Aligned NPOT sizes avoid rounding a
    # slightly overflowing solar/data partition up to four times its area.
    if square:
        choices = [(side*side,side,side,side) for side in range(256,maximum+1,128)
                   if side*side >= minimum and all(r.width+2 <= side and r.height+2 <= side for r in regions)]
    else:
        min_width = max(r.width+2 for r in regions)
        min_height = max(r.height+2 for r in regions)
        choices = sorted((w*h,max(w,h),w,h)
                         for w in range(256,maximum+1,256) for h in range(256,maximum+1,256)
                         if w >= min_width and h >= min_height and w*h >= minimum)
    for _,_,width,height in choices:
        result = pack(regions,width,height)
        if result is not None:
            return {'width':width,'height':height,'occupied_texels':minimum,'regions':result}
    raise ValueError('Resource contract exceeds device texture dimensions')


def volume(name, shape, purpose, bands=1, padding=False):
    x,y,z = shape
    border = 2 if padding else 0
    return Region(name,(x+border)*8,(y+border)*math.ceil(z/8)*bands,purpose)


def build(preset, width, height, maximum=16384):
    """All persistent fields, both banks and native shadow attachments are counted."""
    budgets = {
        'LOW': (48,(128,96,128),24,16,64,1024,.5),
        'MEDIUM': (64,(192,128,192),32,32,128,2048,.5),
        'HIGH': (96,(192,128,192),40,64,128,3072,1.0),
        'ULTRA': (128,(192,128,192),48,64,192,4096,1.0),
    }
    near,far,gi,lights,shadow,solar,scale = budgets[preset]
    rw,rh=max(1,int(width*scale)),max(1,int(height*scale))
    capture=[Region('solar',solar,solar,'日月逻辑投影，不降低所选分辨率'),
             volume('capture_near',(near,)*3,'近场原始几何观察'),
             volume('capture_far',far,'远场原始几何观察'),
             Region('capture_materials',512,384,'全部状态六面原始UV观察'),
             volume('capture_near_faces',(near//2,)*3,'近场逐方块六面UV观察',bands=6)]
    # Shadow capture emits two RGBA records at each logical voxel address.
    raw=atlas(capture,maximum,True)
    persistent=[Region('header',512,16,'布局、原点、代次和工作进度'),
                Region('states',512,192,'32768状态，三纹素定义'),
                Region('material_faces',512,1152,'32768状态六面UV，每面三纹素精确编码'),
                Region('shapes',512,384,'65536旋转包围盒，单状态最多64部件'),
                Region('ore_masks',512,144,'18份64方形矿石遮罩')]
    for name,shape in [('near',(near,)*3),('far',far)]:
        for field in ('material','optics'):
            persistent.append(volume(name+'_'+field,shape,'世界状态/反照率/光照/有效性'))
    near_faces=volume('near_faces',(near//2,)*3,'逐方块六面UV，每面三纹素',bands=6)
    persistent.append(Region(near_faces.name,near_faces.width*3,near_faces.height,near_faces.purpose))
    persistent.append(volume('hue',far,'全部已发现发光体的色相与有效等级',padding=True))
    persistent += [Region('point_shadows',shadow*24,shadow*math.ceil(lights*6/24),'逐光源六面距离/接收平面'),
                   Region('light_selection',512,256,'确定性光源归约与稳定身份'),
                   Region('glass_transfer',(gi+2)*8*8,(gi+2)*math.ceil(gi/8)*math.ceil((lights+1)/8),'接收位置RGB透射')]
    for name in ('published','previous_bounce','step','bounce_sum','total_sum'):
        persistent.append(volume('gi_'+name,(gi,)*3,'RGB一阶球谐场',bands=3,padding=True))
    persistent += [Region('opaque_composed',width,height,'水体透射使用的不透明合成结果'),
                   Region('reflection_work',rw,rh,'当前反射辐射与可信度'),
                   Region('reflection_work_meta',rw,rh,'命中与统计'),
                   Region('reflection_history',rw,rh,'历史RGB及长度'),
                   Region('reflection_surface_history',rw,rh,'接收面深度法线材质'),
                   Region('reflection_statistics',rw,rh,'亮度矩、命中距离和有效性')]
    lw,lh=width,height
    level=0
    while lw>1 or lh>1:
        lw,lh=max(1,(lw+1)//2),max(1,(lh+1)//2)
        persistent.append(Region('hiz_'+str(level),lw,lh,'保守线性深度范围与覆盖'))
        level+=1
    cache=atlas(persistent,maximum)
    allocations=[]
    for index in range(8):
        tw,th=(cache['width'],cache['height']) if index==6 else (width,height)
        bytes_per_pixel=16 if index in (1,7) else 8
        for bank in ('A','B'):
            allocations.append({'name':f'colortex{index}_{bank}','width':tw,'height':th,
                                'format':'RGBA32F' if bytes_per_pixel==16 else 'RGBA16F',
                                'bytes':tw*th*bytes_per_pixel})
    for name,fmt,bpp in [('shadowcolor0','RGBA32F',16),('shadowcolor1','RGBA32F',16),
                         ('shadowtex0','DEPTH32F',4),('shadowtex1','DEPTH32F',4)]:
        allocations.append({'name':name,'width':raw['width'],'height':raw['height'],'format':fmt,
                            'bytes':raw['width']*raw['height']*bpp})
    # Scene depth is independent of the colour attachments and must be included.
    for index in range(3):
        allocations.append({'name':f'depthtex{index}','width':width,'height':height,'format':'DEPTH32F',
                            'bytes':width*height*4})
    allocations.append({'name':'world_static','width':128,'height':64,'depth':64,
                        'format':'RGBA32F','bytes':128*64*64*16})
    return {'schema_version':2,'state_stride':3,'shape_stride':3,'max_shape_parts':64,
            'static_size':[128,64,64],'shape_start':98304,'preset':preset,'viewport':[width,height],'capture':raw,'persistent':cache,
            'near_shape':[near]*3,'near_cell_size':.5,'far_shape':list(far),'far_cell_size':1.0,
            'gi_size':gi,'local_lights':lights,'point_shadow_side':shadow,'solar_side':solar,
            'colour_attachments':8,'max_fragment_samplers':16,'allocations':allocations,
            'allocated_bytes':sum(a['bytes'] for a in allocations),
            'precision':'Half-float integer fields <=2047; identifiers and UV bases split across fields',
            'status':'allocation contract; not implemented rendering features'}


def emit_glsl(contract):
    """One generated coordinate contract is shared by producers and consumers."""
    import hashlib
    cache=contract['persistent']
    names=sorted(cache['regions'])
    signature=int(hashlib.sha256(json.dumps(contract,sort_keys=True).encode()).hexdigest()[:8],16)
    lines=['#ifndef WORLD_ATLAS_LAYOUT_GLSL','#define WORLD_ATLAS_LAYOUT_GLSL',
           f'const uint WORLD_LAYOUT_SIGNATURE = {signature}u;',
           f'const ivec2 WORLD_ATLAS_SIZE = ivec2({cache["width"]},{cache["height"]});',
           f'const ivec3 WORLD_NEAR_SHAPE = ivec3({contract["near_shape"][0]});',
           'const ivec3 WORLD_FAR_SHAPE = ivec3('+','.join(map(str,contract['far_shape']))+');',
           f'const int WORLD_REGION_COUNT = {len(names)};',
           'const int WORLD_STATE_STRIDE = 3;',
           'const int WORLD_SHAPE_STRIDE = 3;',
           'const int WORLD_MAX_SHAPE_PARTS = 64;',
           'const int WORLD_SHAPE_START = 98304;',
           'const ivec3 WORLD_STATIC_SIZE = ivec3(128,64,64);']
    for index,name in enumerate(names):
        lines.append(f'const int WORLD_REGION_{name.upper()} = {index};')
    lines.append('ivec4 worldRegion(int region) {')
    for index,name in enumerate(names):
        r=cache['regions'][name]
        lines.append(f'    if (region == {index}) return ivec4({r["x"]},{r["y"]},{r["width"]},{r["height"]});')
    lines += ['    return ivec4(-1);','}',
              'ivec2 worldAtlasPixel(int region, ivec2 pixel) {',
              '    ivec4 rectangle = worldRegion(region);',
              '    if (region < 0 || rectangle.z < 0 || any(lessThan(pixel,ivec2(0)))',
              '        || any(greaterThanEqual(pixel,rectangle.zw))) return ivec2(-1);',
              '    return rectangle.xy + pixel;','}',
              'ivec2 worldVoxelAddress(ivec3 cell, ivec3 size, int padding, int band) {',
              '    if (any(lessThan(cell,ivec3(0))) || any(greaterThanEqual(cell,size))) return ivec2(-1);',
              '    ivec2 tile = size.xy + ivec2(padding*2);',
              '    int rows = (size.z+7)/8;',
              '    return ivec2(cell.z%8,cell.z/8) * tile + cell.xy + ivec2(padding)',
              '         + ivec2(0,band*rows*tile.y);','}', '#endif','']
    return '\n'.join(lines)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--width',type=int,default=1920)
    parser.add_argument('--height',type=int,default=1080)
    parser.add_argument('--output',type=Path,default=ROOT/'local-docs/migration/layout')
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    for preset in ('LOW','MEDIUM','HIGH','ULTRA'):
        result=build(preset,args.width,args.height)
        name=args.output/preset.lower()
        name.with_suffix('.glsl').write_text(emit_glsl(result))
        name.with_suffix('.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        name.with_suffix('.alloc').write_text(''.join(f"{a['name']} {a['width']} {a['height']} {a['format']} {a.get('depth',1)}\n" for a in result['allocations']))
        print(preset,result['persistent']['width'],result['persistent']['height'],round(result['allocated_bytes']/1048576,1),'MiB')


if __name__=='__main__':
    main()
